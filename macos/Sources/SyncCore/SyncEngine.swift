import Foundation

public struct TransferProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentPath: String

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    public init(completed: Int, total: Int, currentPath: String) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }
}

public enum SyncEngineError: LocalizedError {
    case invalidProfile([String])
    case remotePathMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let problems):
            return problems.joined(separator: " ")
        case .remotePathMissing(let path):
            return "Der Ordner \(path) existiert auf dem Server nicht. „Verbindung testen“ legt ihn an."
        }
    }
}

/// Fuehrt Pruefung und Uebertragung aus. Kennt kein UI und keine Views,
/// damit sich alles hier mit einem eingesetzten Runner testen laesst.
public final class SyncEngine {
    private let runner: RsyncExecuting
    private let stateStore: SyncStateStore
    private let inventoryStore: InventoryStore
    private let knownHosts: URL
    private let identity: URL
    /// Wo der Arbeitsordner eines Laufs ohne SSH-Sitzung entsteht.
    private let workspaceParent: URL

    public init(
        runner: RsyncExecuting = RsyncRunner(),
        stateStore: SyncStateStore = SyncStateStore(),
        inventoryStore: InventoryStore = InventoryStore(),
        knownHosts: URL = AppPaths.knownHostsFile,
        identity: URL = AppPaths.privateKeyFile,
        workspaceParent: URL = FileManager.default.temporaryDirectory
    ) {
        self.runner = runner
        self.stateStore = stateStore
        self.inventoryStore = inventoryStore
        self.knownHosts = knownHosts
        self.identity = identity
        self.workspaceParent = workspaceParent
    }

    public func cancel() { runner.cancel() }

    // MARK: - Prüfen

    /// Listet beide Seiten vollstaendig auf und wertet die beiden Bestaende aus.
    ///
    /// Frueher waren das zwei Differenz-Trockenlaeufe, aus denen sich die Lage
    /// nur erschliessen liess. Jetzt steht fuer jeden Pfad fest, ob es ihn
    /// drueben gibt. Die Fernseite kostet eine Anmeldung, die lokalen Laeufe keine.
    public func check(
        profile: Profile,
        password: String?,
        rsyncPath: String,
        supportsChecksumField: Bool = true,
        onLog: ((String) -> Void)? = nil
    ) async throws -> SyncStatus {
        try validate(profile)

        // Nur ssh braucht eine Sitzung. Ein lokaler Lauf haette hier sonst am
        // fehlenden Passwort scheitern koennen, obwohl er keines braucht.
        let session = try openSession(for: profile, password: password)
        defer { session?.stop() }

        let context = try prepare(session: session, profile: profile)
        defer { context.cleanup() }
        let emptyDirectory = try context.emptyDirectory()
        // openrsync kennt `%C` nicht und schriebe das Literal in die Zeile.
        let wantsChecksums = profile.useChecksum && supportsChecksumField

        onLog?("Bestand auf dem Server")
        let remote = try await inventory(
            profile: profile,
            options: .init(
                side: .remote,
                emptyDirectory: emptyDirectory,
                remoteShell: context.remoteShell,
                excludeFile: context.excludeFile,
                wantsChecksums: wantsChecksums,
                endpoints: context.endpoints
            ),
            rsyncPath: rsyncPath, environment: context.environment, onLog: onLog
        )

        onLog?("Bestand auf diesem Rechner")
        let local = try await inventory(
            profile: profile,
            options: .init(
                side: .local,
                emptyDirectory: emptyDirectory,
                excludeFile: context.excludeFile,
                wantsChecksums: wantsChecksums,
                endpoints: context.endpoints
            ),
            rsyncPath: rsyncPath, environment: context.environment, onLog: onLog
        )

        let status = DriftResolver.resolve(
            remote: remote,
            local: local,
            lastSync: stateStore.load().lastSync(for: profile),
            knownPaths: inventoryStore.trustedPaths(for: profile, remotePaths: remote.paths),
            excludedPaths: try await excludedPaths(
                profile: profile,
                emptyDirectory: emptyDirectory,
                covered: local.paths,
                rsyncPath: rsyncPath,
                environment: context.environment,
                endpoints: context.endpoints,
                onLog: onLog
            )
        )
        onLog?(summary(for: status))
        return status
    }

    /// Was lokal liegt, die Ausschlussliste aber verdeckt.
    ///
    /// Derselbe Lauf noch einmal ohne `--exclude-from`, die Differenz ist die
    /// Antwort. Rein lokal, kostet keine Anmeldung. Ohne Ausschluesse im Profil
    /// gibt es nichts zu vergleichen.
    private func excludedPaths(
        profile: Profile,
        emptyDirectory: String,
        covered: Set<String>,
        rsyncPath: String,
        environment: [String: String],
        endpoints: SyncEndpoints,
        onLog: ((String) -> Void)?
    ) async throws -> [String] {
        guard !profile.excludes.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .isEmpty
        else { return [] }

        let complete = try await inventory(
            profile: profile,
            options: .init(
                side: .local, emptyDirectory: emptyDirectory, excludeFile: nil,
                wantsChecksums: false, endpoints: endpoints
            ),
            rsyncPath: rsyncPath, environment: environment, onLog: nil
        )
        let excluded = complete.paths.subtracting(covered).sorted()
        if !excluded.isEmpty {
            onLog?("\(excluded.count) Einträge bleiben durch die Ausschlussliste außen vor.")
        }
        return excluded
    }

    private func inventory(
        profile: Profile,
        options: RsyncArguments.InventoryOptions,
        rsyncPath: String,
        environment: [String: String],
        onLog: ((String) -> Void)?
    ) async throws -> SideInventory {
        let plan = RsyncPlan(
            executable: rsyncPath,
            arguments: RsyncArguments.inventoryArguments(profile: profile, options: options),
            environment: environment
        )
        onLog?("$ \(plan.displayCommand)")

        var entries: [InventoryEntry] = []
        let outcome = try await runner.execute(plan) { line in
            if let entry = ItemizeParser.parseInventoryLine(
                line, withChecksum: options.wantsChecksums
            ) {
                entries.append(entry)
            } else {
                onLog?(line)
            }
        }
        try verify(outcome, profile: profile, side: options.side)
        return InventoryBuilder.build(from: entries)
    }

    /// Ein Bestandslauf, der nicht sauber durchlief, liefert eine unvollstaendige
    /// Liste. Die als Bestand zu nehmen hiesse, fehlende Dateien als geloescht
    /// zu melden, deshalb bricht das hier ab.
    private func verify(
        _ outcome: RsyncOutcome, profile: Profile, side: RsyncArguments.InventorySide
    ) throws {
        guard !outcome.succeeded && !outcome.isWarningOnly else { return }
        let detail = outcome.errorLines.last ?? "keine Fehlermeldung"
        if detail.lowercased().contains("no such file") && side == .remote {
            throw SyncEngineError.remotePathMissing(profile.remotePath)
        }
        throw RsyncError.failed(status: outcome.status, detail: detail)
    }

    // MARK: - Übertragen

    public func transfer(
        profile: Profile,
        password: String?,
        direction: SyncDirection,
        includeDeletes: Bool,
        protectedPaths: [String] = [],
        expectedItems: Int,
        /// Die beim Pruefen gemessenen Bestaende. Daraus entsteht der neue
        /// gemeinsame Bestand, statt ihn aus dem lokalen Baum zu raten.
        remotePaths: Set<String> = [],
        localPaths: Set<String> = [],
        rsyncPath: String,
        onLog: ((String) -> Void)? = nil,
        onProgress: ((TransferProgress) -> Void)? = nil
    ) async throws -> RsyncOutcome {
        try validate(profile)
        // Vor der Anmeldung, nicht danach: der Abbruch kostet so keine
        // Verbindung und keine Wartezeit.
        try guardTarget(
            profile: profile, direction: direction, includeDeletes: includeDeletes,
            remotePaths: remotePaths, localPaths: localPaths, onLog: onLog
        )

        let session = try openSession(for: profile, password: password)
        defer { session?.stop() }

        let context = try prepare(
            session: session, profile: profile, protectedPaths: protectedPaths
        )
        defer { context.cleanup() }
        let options = RsyncArguments.Options(
            dryRun: false,
            includeDeletes: includeDeletes,
            remoteShell: context.remoteShell,
            excludeFile: context.excludeFile,
            protectFile: context.protectFile,
            endpoints: context.endpoints,
            flavour: context.flavour
        )

        var completed = 0
        let outcome = try await run(
            profile: profile,
            direction: direction,
            options: options,
            rsyncPath: rsyncPath,
            environment: context.environment,
            onLog: onLog,
            onLine: { line in
                guard let item = ItemizeParser.parseLine(line) else { return }
                completed += 1
                onProgress?(
                    TransferProgress(
                        completed: completed,
                        total: max(expectedItems, completed),
                        currentPath: item.path
                    )
                )
            }
        )

        stateStore.recordSync(for: profile)
        inventoryStore.record(
            for: profile,
            commonPaths: SyncInventory.afterTransfer(
                previous: inventoryStore.load(for: profile)?.paths ?? [],
                remote: remotePaths,
                local: localPaths,
                direction: direction,
                includeDeletes: includeDeletes && profile.deleteAllowed,
                succeeded: outcome.succeeded || outcome.isWarningOnly
            )
        )
        return outcome
    }

    // MARK: - Absturzsicherung

    /// Bricht ab, wenn die Quellseite unerwartet leer ist.
    ///
    /// Die Zahlen stammen aus der Pruefung, die diesem Lauf vorausging, nicht
    /// aus einer neuen Messung: es geht um genau die Bestaende, auf deren
    /// Grundlage der Nutzer "Loeschen" angehakt hat.
    private func guardTarget(
        profile: Profile,
        direction: SyncDirection,
        includeDeletes: Bool,
        remotePaths: Set<String>,
        localPaths: Set<String>,
        onLog: ((String) -> Void)?
    ) throws {
        let source = direction == .push ? localPaths : remotePaths
        let destination = direction == .push ? remotePaths : localPaths
        let facts = TargetFacts(
            direction: direction,
            sourcePathCount: source.count,
            destinationPathCount: destination.count,
            rememberedPathCount: inventoryStore.load(for: profile)?.paths.count ?? 0,
            expectedMarker: profile.targetMarkerID,
            // Wird noch nicht nachgesehen. Die Kennung kommt mit den
            // eingehaengten Zielen.
            markerFound: nil
        )
        // Dieselbe Bedingung wie in RsyncArguments: der Aufrufer muss loeschen
        // wollen, und das Profil muss es erlauben.
        guard
            let problem = TargetGuard.decide(
                facts, needsDelete: includeDeletes && profile.deleteAllowed
            )
        else { return }
        onLog?(problem.localizedDescription)
        throw problem
    }

    // MARK: - Intern

    private struct RunContext {
        /// Leer, wenn dieser Lauf keine Gegenstelle hat.
        let remoteShell: String
        let excludeFile: String?
        let protectFile: String?
        let environment: [String: String]
        let endpoints: SyncEndpoints
        let flavour: RsyncFlavour
        /// Arbeitsordner fuer Ausschluss- und Schutzdatei.
        let directory: URL
        /// Gehoert der Ordner uns? Der Sitzungsordner raeumt sich mit der
        /// Sitzung selbst auf, ein eigener nicht.
        let ownsDirectory: Bool

        /// Ziel der Bestandslaeufe. Bleibt leer, `--dry-run` schreibt nichts.
        func emptyDirectory() throws -> String {
            let url = directory.appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return url.path
        }

        func cleanup() {
            guard ownsDirectory else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Eine Sitzung nur da, wo rsync eine Gegenstelle braucht.
    ///
    /// `SSHSession.start` wirft ohne Passwort, sobald das Profil auf
    /// Passwortanmeldung steht. Ein Lauf im Dateisystem waere daran gescheitert,
    /// obwohl er sich nirgends anmeldet.
    private func openSession(for profile: Profile, password: String?) throws -> SSHSession? {
        guard profile.transport.usesRemoteShell else { return nil }
        let session = try SSHSession(profile: profile, knownHosts: knownHosts, identity: identity)
        do {
            try session.start(password: password)
        } catch {
            session.stop()
            throw error
        }
        return session
    }

    private func prepare(
        session: SSHSession?, profile: Profile, protectedPaths: [String] = []
    ) throws -> RunContext {
        let remoteShell: String
        let directory: URL
        let environment: [String: String]
        let ownsDirectory: Bool

        if let session {
            remoteShell = try session.remoteShellPath()
            // Derselbe Ordner wie das rsh-Skript: er verschwindet mit der Sitzung.
            directory = URL(fileURLWithPath: remoteShell).deletingLastPathComponent()
            environment = try session.environment
            ownsDirectory = false
        } else {
            remoteShell = ""
            directory = try makeWorkspace()
            environment = [:]
            ownsDirectory = true
        }

        let excludeFile = try RsyncArguments.writeExcludeFile(profile.excludes, in: directory)
        let protectFile = try RsyncArguments.writeProtectFile(protectedPaths, in: directory)
        return RunContext(
            remoteShell: remoteShell,
            excludeFile: excludeFile,
            protectFile: protectFile,
            environment: environment,
            endpoints: SyncEndpoints.resolve(profile: profile),
            flavour: RsyncFlavour.forTransport(profile.transport),
            directory: directory,
            ownsDirectory: ownsDirectory
        )
    }

    /// Arbeitsordner fuer einen Lauf ohne Sitzung.
    ///
    /// 0700 wie der Sitzungsordner: darin liegen die Ausschluss- und
    /// Schutzregeln, und die verraten die Ordnerstruktur des Nutzers.
    private func makeWorkspace() throws -> URL {
        let url = workspaceParent
            .appendingPathComponent("synctool-lauf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func run(
        profile: Profile,
        direction: SyncDirection,
        options: RsyncArguments.Options,
        rsyncPath: String,
        environment: [String: String],
        onLog: ((String) -> Void)?,
        onLine: ((String) -> Void)? = nil
    ) async throws -> RsyncOutcome {
        let plan = RsyncPlan(
            executable: rsyncPath,
            arguments: RsyncArguments.arguments(
                profile: profile, direction: direction, options: options
            ),
            environment: environment
        )
        onLog?("$ \(plan.displayCommand)")

        let outcome = try await runner.execute(plan) { line in
            onLine?(line)
            onLog?(line)
        }

        if !outcome.succeeded && !outcome.isWarningOnly {
            let detail = outcome.errorLines.last ?? "keine Fehlermeldung"
            if detail.lowercased().contains("no such file") && direction == .pull {
                throw SyncEngineError.remotePathMissing(profile.remotePath)
            }
            throw RsyncError.failed(status: outcome.status, detail: detail)
        }
        return outcome
    }

    private func validate(_ profile: Profile) throws {
        let problems = profile.validationErrors()
        guard problems.isEmpty else { throw SyncEngineError.invalidProfile(problems) }
    }

    private func summary(for status: SyncStatus) -> String {
        var parts: [String] = []
        if status.isInSync {
            parts.append("alles auf gleichem Stand")
        } else {
            if !status.incoming.isEmpty { parts.append("\(status.incoming.count) herunterzuladen") }
            if !status.outgoing.isEmpty { parts.append("\(status.outgoing.count) hochzuladen") }
            if !status.conflicts.isEmpty { parts.append("\(status.conflicts.count) im Konflikt") }
            if !status.deletionsOnPush.isEmpty {
                parts.append("\(status.deletionsOnPush.count) lokal gelöscht")
            }
            if !status.deletionsOnPull.isEmpty {
                parts.append("\(status.deletionsOnPull.count) auf dem Server gelöscht")
            }
        }
        return "Ergebnis: " + parts.joined(separator: ", ") + "."
    }
}
