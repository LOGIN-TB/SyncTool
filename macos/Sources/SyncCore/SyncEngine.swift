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
    case gitDeleteLimit(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let problems):
            return problems.joined(separator: " ")
        case .remotePathMissing(let path):
            return "Der Ordner \(path) existiert auf dem Server nicht. „Verbindung testen“ legt ihn an."
        case .gitDeleteLimit(let limit):
            return "In den Git-Repos standen mehr als \(limit) Löschungen an. "
                + "Mindestens ein .git ist deshalb nur halb übertragen. "
                + "Noch einmal prüfen und den Lauf wiederholen."
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
            settledGitBranches: try await settledBranches(
                profile: profile, remote: remote, local: local, context: context,
                rsyncPath: rsyncPath, onLog: onLog
            ),
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

    /// Welche Repos auf beiden Seiten auf denselben Zeigern stehen.
    ///
    /// git packt von sich aus um, nach jedem `fetch` und nach genug Commits.
    /// Danach haben beide Rechner dieselben Commits in verschieden benannten
    /// Packdateien, und ein Vergleich Datei fuer Datei haelt das fuer
    /// beidseitige Arbeit. Deshalb kommen hier `HEAD`, `packed-refs` und alles
    /// unter `refs/` von der Gegenseite herueber, ein paar Kilobyte je Repo,
    /// und verglichen wird daran.
    ///
    /// Geht das schief, ist das kein Grund abzubrechen: dann bleibt es beim
    /// Vergleich ueber die Dateien, so wie vorher.
    private func settledBranches(
        profile: Profile,
        remote: SideInventory,
        local: SideInventory,
        context: RunContext,
        rsyncPath: String,
        onLog: ((String) -> Void)?
    ) async throws -> Set<String> {
        let bare = GitRepositories.bareBranches(remote: remote, local: local)
        let branches = Set(
            remote.paths.union(local.paths).compactMap { GitRepositories.branch(of: $0, bare: bare) }
        )
        guard !branches.isEmpty else { return [] }

        guard
            let filterFile = try? RsyncArguments.writeRefFilterFile(
                branches: branches.sorted(), in: context.directory
            )
        else { return [] }
        let harvest = context.directory.appendingPathComponent("refs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: harvest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: harvest) }

        let plan = RsyncPlan(
            executable: rsyncPath,
            arguments: RsyncArguments.refArguments(
                profile: profile,
                filterFile: filterFile,
                destination: harvest.path,
                remoteShell: context.remoteShell,
                flavour: context.flavour,
                endpoints: context.endpoints
            ),
            environment: context.environment
        )
        onLog?("$ \(plan.displayCommand)")
        let outcome = try await runner.execute(plan, onLine: nil)
        guard outcome.succeeded || outcome.isWarningOnly else {
            onLog?("Die Zeiger der Repos ließen sich nicht lesen, verglichen wird über die Dateien.")
            return []
        }

        var settled: Set<String> = []
        for branch in branches {
            let here = GitRefs.read(
                gitDirectory: (profile.localRoot as NSString).appendingPathComponent(branch)
            )
            let there = GitRefs.read(
                gitDirectory: harvest.appendingPathComponent(branch).path
            )
            if GitRefs.settled(here, there) { settled.insert(branch) }
        }
        if !settled.isEmpty {
            onLog?("\(settled.count) Repo(s) stehen beidseitig auf denselben Zeigern.")
        }
        return settled
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

    /// Zuschlag auf die gemessene Zahl der Loeschungen im Git-Lauf.
    /// Zwischen Pruefen und Uebertragen bewegt sich etwas.
    private static let gitDeleteMargin = 50

    /// Die Notbremse des Git-Laufs, aus den gemessenen Bestaenden gerechnet.
    ///
    /// `profile.maxDelete` taugt hier nicht: nach einem `git gc` auf der
    /// Senderseite faellt drueben ein Vielfaches davon weg. Gezaehlt wird
    /// deshalb, was auf der Empfaengerseite unter den freigegebenen Zweigen
    /// liegt und auf der Senderseite nicht, also genau das, was der Lauf
    /// wegraeumen wird. Bewusst ueber die Pfadmengen und nicht ueber die
    /// Drift-Listen: Verzeichnisse mit Inhalt stehen dort nicht drin, rsync
    /// loescht sie aber mit.
    ///
    /// Ohne gemessene Bestaende bleibt es beim Anschlag aus dem Profil.
    private func gitDeleteLimit(
        mirrored: [String],
        direction: SyncDirection,
        remotePaths: Set<String>,
        localPaths: Set<String>,
        profile: Profile
    ) -> Int {
        guard !remotePaths.isEmpty, !localPaths.isEmpty else { return profile.maxDelete }
        let receiver = direction == .pull ? localPaths : remotePaths
        let sender = direction == .pull ? remotePaths : localPaths
        let doomed = receiver.subtracting(sender).count { path in
            mirrored.contains { path.hasPrefix($0) }
        }
        return doomed + Self.gitDeleteMargin
    }

    public func transfer(
        profile: Profile,
        password: String?,
        direction: SyncDirection,
        includeDeletes: Bool,
        protectedPaths: [String] = [],
        expectedItems: Int,
        /// Die Git-Repos aus der Pruefung. Was in diese Richtung laeuft, geht im
        /// zweiten Lauf als Einheit hinueber, alles andere bleibt unberuehrt.
        gitUnits: [GitUnit] = [],
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

        let wanted: GitUnitState = direction == .pull ? .incoming : .outgoing
        let mirrored = gitUnits.filter { $0.state == wanted }.map(\.branch).sorted()
        // Der Hauptlauf laesst jeden `.git`-Zweig aus, auch die, die gleich
        // drankommen: dort gelten andere Regeln.
        let skipped = gitUnits.map(\.branch).sorted()
        let frozen = skipped.filter { !mirrored.contains($0) }

        let session = try openSession(for: profile, password: password)
        defer { session?.stop() }

        let context = try prepare(
            session: session, profile: profile, protectedPaths: protectedPaths,
            skippedBranches: skipped, gitBranches: mirrored
        )
        defer { context.cleanup() }

        let deleteLimit = gitDeleteLimit(
            mirrored: mirrored, direction: direction,
            remotePaths: remotePaths, localPaths: localPaths, profile: profile
        )
        let options = RsyncArguments.Options(
            dryRun: false,
            includeDeletes: includeDeletes,
            remoteShell: context.remoteShell,
            excludeFile: context.excludeFile,
            protectFile: context.protectFile,
            endpoints: context.endpoints,
            flavour: context.flavour,
            gitFilterFile: context.gitFilterFile,
            gitMaxDelete: deleteLimit
        )

        var completed = 0
        let report: (String) -> Void = { line in
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

        /// Schreibt den gemeinsamen Bestand fort. Bei einem Fehlschlag bleibt
        /// nur die Schnittmenge uebrig, sonst gaelte ein nie angekommener Pfad
        /// beim naechsten Pruefen als hier geloescht.
        func record(succeeded: Bool) {
            stateStore.recordSync(for: profile)
            inventoryStore.record(
                for: profile,
                commonPaths: SyncInventory.afterTransfer(
                    previous: inventoryStore.load(for: profile)?.paths ?? [],
                    remote: remotePaths,
                    local: localPaths,
                    direction: direction,
                    includeDeletes: includeDeletes && profile.deleteAllowed,
                    succeeded: succeeded,
                    mirroredBranches: succeeded ? mirrored : [],
                    frozenBranches: frozen
                )
            )
        }

        var outcome: RsyncOutcome
        do {
            outcome = try await run(
                arguments: RsyncArguments.arguments(
                    profile: profile, direction: direction, options: options
                ),
                direction: direction,
                remotePath: profile.remotePath,
                rsyncPath: rsyncPath,
                environment: context.environment,
                onLog: onLog,
                onLine: report
            )

            // Erst der Hauptlauf, dann die Repos. Bricht etwas dazwischen ab,
            // bleibt das `.git` der Empfaengerseite auf seinem alten, in sich
            // stimmigen Stand. Andersherum zeigten neue Refs auf eine alte
            // Arbeitskopie, und das sieht nach verlorener Arbeit aus.
            if !mirrored.isEmpty {
                onLog?("\(mirrored.count) Git-Repo(s) als Einheit übertragen")
                let gitOutcome = try await run(
                    arguments: RsyncArguments.gitArguments(
                        profile: profile, direction: direction, options: options
                    ),
                    direction: direction,
                    remotePath: profile.remotePath,
                    rsyncPath: rsyncPath,
                    environment: context.environment,
                    onLog: onLog,
                    onLine: report
                )
                outcome = merged(outcome, gitOutcome)

                // openrsync bricht an `--max-delete` nicht ab, es hoert still
                // auf zu loeschen. Genau dann bleibt ein halbes `.git` liegen,
                // deshalb wird hier nachgezaehlt.
                let removed = gitOutcome.items.count { $0.kind == .deleted }
                if removed >= deleteLimit {
                    record(succeeded: false)
                    throw SyncEngineError.gitDeleteLimit(limit: deleteLimit)
                }
            }
        } catch {
            record(succeeded: false)
            throw error
        }

        record(succeeded: outcome.succeeded || outcome.isWarningOnly)
        return outcome
    }

    /// Fuegt die Ergebnisse beider Laeufe zusammen. Der schlechtere Status
    /// gewinnt, damit ein Fehler im zweiten Lauf nicht hinter der Null des
    /// ersten verschwindet.
    private func merged(_ first: RsyncOutcome, _ second: RsyncOutcome) -> RsyncOutcome {
        func rank(_ status: Int32) -> Int { status == 0 ? 0 : (status == 24 ? 1 : 2) }
        return RsyncOutcome(
            status: rank(second.status) > rank(first.status) ? second.status : first.status,
            items: first.items + second.items,
            errorLines: first.errorLines + second.errorLines,
            statsLines: first.statsLines + second.statsLines,
            skippedLinkAttributes: first.skippedLinkAttributes + second.skippedLinkAttributes
        )
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
        /// Einschlussregeln des Git-Laufs. `nil` heisst: in dieser Richtung
        /// steht kein Repo an.
        let gitFilterFile: String?
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
        session: SSHSession?,
        profile: Profile,
        protectedPaths: [String] = [],
        skippedBranches: [String] = [],
        gitBranches: [String] = []
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

        let excludeFile = try RsyncArguments.writeExcludeFile(
            profile.excludes, branches: skippedBranches, in: directory
        )
        let protectFile = try RsyncArguments.writeProtectFile(protectedPaths, in: directory)
        let gitFilterFile = try RsyncArguments.writeGitFilterFile(
            branches: gitBranches, in: directory
        )
        return RunContext(
            remoteShell: remoteShell,
            excludeFile: excludeFile,
            protectFile: protectFile,
            gitFilterFile: gitFilterFile,
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
        arguments: [String],
        direction: SyncDirection,
        /// Nur fuer die Fehlermeldung, wenn die Gegenseite den Ordner nicht hat.
        remotePath: String,
        rsyncPath: String,
        environment: [String: String],
        onLog: ((String) -> Void)?,
        onLine: ((String) -> Void)? = nil
    ) async throws -> RsyncOutcome {
        let plan = RsyncPlan(
            executable: rsyncPath,
            arguments: arguments,
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
                throw SyncEngineError.remotePathMissing(remotePath)
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
