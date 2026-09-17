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
    case deleteLimit(limit: Int, direction: SyncDirection)
    case incompleteInventory
    case targetBusy(note: String)

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
        case .targetBusy(let note):
            let wer = note.split(separator: "\n").first.map(String.init) ?? "ein anderer Rechner"
            return "Auf dem Ziel läuft gerade ein Abgleich von \(wer). "
                + "Zwei Läufe gleichzeitig können sich gegenseitig Dateien wegräumen, "
                + "die der jeweils andere eben geschrieben hat. Später noch einmal versuchen."
        case .incompleteInventory:
            return "Während der Prüfung haben sich Dateien bewegt, die Bestandsliste "
                + "ist deshalb unvollständig. Auf dieser Grundlage wird nichts gelöscht: "
                + "Eine Datei, die beim Auflisten verschwand, sieht genauso aus wie eine "
                + "gelöschte. Noch einmal prüfen."
        case .deleteLimit(let limit, let direction):
            let seite = direction == .pull ? "hier" : "auf der Gegenstelle"
            return "Der Lauf hat die Grenze von \(limit) Löschungen erreicht. "
                + "Es wurde weniger \(seite) entfernt als angekündigt, beide Seiten "
                + "stehen deshalb auf einem Mischzustand. Noch einmal prüfen und "
                + "nachsehen, warum so viel zum Löschen anstand."
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
    /// Wie der Motor an Sperre und gemeinsamen Stand im Zielordner kommt.
    /// Einsetzbar, damit Tests nicht an echten ssh-Aufrufen haengen.
    private let remoteFiles: (Profile, SSHSession?, SyncEndpoints) -> RemoteFiles?

    public init(
        runner: RsyncExecuting = RsyncRunner(),
        stateStore: SyncStateStore = SyncStateStore(),
        inventoryStore: InventoryStore = InventoryStore(),
        knownHosts: URL = AppPaths.knownHostsFile,
        identity: URL = AppPaths.privateKeyFile,
        workspaceParent: URL = FileManager.default.temporaryDirectory,
        remoteFiles: @escaping (Profile, SSHSession?, SyncEndpoints) -> RemoteFiles? =
            RemoteStore.make
    ) {
        self.runner = runner
        self.stateStore = stateStore
        self.inventoryStore = inventoryStore
        self.knownHosts = knownHosts
        self.identity = identity
        self.workspaceParent = workspaceParent
        self.remoteFiles = remoteFiles
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

        // Der Stand der Gegenstelle wird gelesen, aber er entscheidet nichts.
        //
        // Das war anders gedacht und ist an einem Test gescheitert, der recht
        // hatte: `knownPaths` beantwortet die Frage "stand dieser Pfad beim
        // letzten Abgleich auf BEIDEN Seiten", und "beide" heisst hier: die
        // Gegenstelle und *dieser* Rechner. Nimmt man dafuer den Bestand eines
        // anderen Rechners, kippt die Antwort ins Gegenteil: Eine Datei, die A
        // gerade erst hochgeladen hat, stuende in As Bestand, und B, der sie
        // nie hatte, hielte sie fuer eine, die er selbst geloescht hat. Statt
        // sie herunterzuladen, boete er an, sie drueben wegzuraeumen.
        //
        // Das lokale Gedaechtnis ist fuer diese Frage die richtige Quelle, und
        // es beantwortet sie auch mit mehreren Rechnern richtig. Was zwischen
        // Rechnern wirklich fehlte, ist nichts, was man ausrechnen kann,
        // sondern dass nicht zwei gleichzeitig laufen. Dafuer gibt es die
        // Sperre in `transfer`.
        let shared = SharedState.decoded(
            (await remoteFiles(profile, session, context.endpoints)?
                .read(SharedState.fileName)) ?? Data()
        )
        var lastRemoteRun: SyncStatus.RemoteRun?
        if let shared, shared.lastMachine != SharedState.machineName {
            lastRemoteRun = .init(machine: shared.lastMachine, at: shared.writtenAt)
            onLog?(
                "Zuletzt abgeglichen von \(shared.lastMachine), "
                    + Format.timestamp(shared.writtenAt) + "."
            )
        }

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
            ),
            lastRemoteRun: lastRemoteRun
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
        // Status 24 laesst `verify` durch, und das ist richtig: In einem
        // Entwicklungsordner bewegt sich staendig etwas, und deshalb den
        // ganzen Lauf abzubrechen hiesse, die App unbenutzbar zu machen. Die
        // Liste ist dann aber unvollstaendig, und das muss mitwandern: Ein
        // Eintrag, der waehrend der Auflistung verschwand, sieht hinterher aus
        // wie einer, den jemand geloescht hat.
        return InventoryBuilder.build(from: entries, isComplete: outcome.succeeded)
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

    /// Derselbe Zuschlag fuer den Hauptlauf.
    private static let deleteMargin = 50

    /// Hat der Lauf so viel geloescht, wie er hoechstens durfte?
    ///
    /// openrsync bricht an `--max-delete` nicht ab, es hoert still auf zu
    /// loeschen und meldet Erfolg. Ein Lauf, der 5.000 Eintraege wegraeumen
    /// wollte, raeumt dann 100 weg, und beide Seiten stehen danach auf einem
    /// Mischzustand, von dem niemand etwas erfaehrt. Gezaehlt wird deshalb
    /// nach. rsync 3.x bricht von sich aus mit Status 25 ab, dort faellt das
    /// schon vorher auf; die Zaehlung schadet ihm nicht.
    private func reachedDeleteLimit(_ outcome: RsyncOutcome, limit: Int) -> Bool {
        outcome.items.count { $0.kind == .deleted } >= limit
    }

    /// Die Notbremse des Hauptlaufs.
    ///
    /// Zwei Anschlaege, der kleinere gilt. `profile.maxDelete` ist die absolute
    /// Grenze und sagt nichts ueber diesen Lauf. Die gemessene Zahl plus
    /// Zuschlag ist die Zusage, die das Statusfenster dem Nutzer gemacht hat:
    /// Wer dort "17 Dateien löschen?" bestaetigt, hat nicht 100 erlaubt.
    ///
    /// Ohne gemessene Zahl bleibt es beim Anschlag aus dem Profil, genau wie
    /// beim Git-Lauf.
    private func deleteLimit(expected: Int?, profile: Profile) -> Int {
        guard let expected else { return profile.maxDelete }
        return min(profile.maxDelete, expected + Self.deleteMargin)
    }

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
        /// Wie viele Loeschungen die Pruefung angekuendigt hat. `nil` heisst:
        /// nicht gemessen, dann bleibt es beim Anschlag aus dem Profil.
        expectedDeletions: Int? = nil,
        protectedPaths: [String] = [],
        expectedItems: Int,
        /// Die Git-Repos aus der Pruefung. Was in diese Richtung laeuft, geht im
        /// zweiten Lauf als Einheit hinueber, alles andere bleibt unberuehrt.
        gitUnits: [GitUnit] = [],
        /// Die beim Pruefen gemessenen Bestaende. Daraus entsteht der neue
        /// gemeinsame Bestand, statt ihn aus dem lokalen Baum zu raten.
        remotePaths: Set<String> = [],
        localPaths: Set<String> = [],
        /// Wann die Pruefung lief, auf der dieser Lauf beruht. `nil` heisst:
        /// unbekannt, dann zaehlt der Zeitpunkt des Laufs.
        checkedAt: Date? = nil,
        rsyncPath: String,
        /// `false` bei openrsync: die Fassung vertraegt `-b` und `--delete`
        /// nicht in derselben Zeile. Siehe `Options.backupFlags`.
        ///
        /// `nil` heisst: selbst nachsehen. Das ist die Vorgabe, und zwar aus
        /// Erfahrung: Stand hier `true` als Vorgabe, verlor ein Aufrufer, der
        /// nichts uebergab, bei openrsync stillschweigend das Loeschen. Ein
        /// Fehler, den man vergessen kann, ist einer, der passiert.
        supportsBackupWhileDeleting: Bool? = nil,
        /// Liefen die Bestandslaeufe der zugrundeliegenden Pruefung sauber
        /// durch? Auf einer luckenhaften Liste wird nicht geloescht.
        inventoryComplete: Bool = true,
        /// Genau die Pfade, die dieser Lauf uebertragen soll: `incoming` beim
        /// Herunterladen, `outgoing` beim Hochladen. Konflikte stehen in keiner
        /// der beiden Listen und bleiben dadurch unberuehrt.
        ///
        /// `nil` heisst: nicht gemessen, dann geht der ganze Baum wie frueher.
        /// Ein leeres Feld heisst: gemessen, und es ist nichts zu uebertragen.
        /// Der Unterschied ist wichtig, sonst uebertruege ein Lauf ohne
        /// Messung gar nichts mehr.
        transferPaths: [String]? = nil,
        onLog: ((String) -> Void)? = nil,
        onProgress: ((TransferProgress) -> Void)? = nil
    ) async throws -> RsyncOutcome {
        try validate(profile)
        // Die Sperre haengt nicht am Haken im Statusfenster, sondern hier:
        // Eine unvollstaendige Bestandsliste ist keine Grundlage, auf der
        // geloescht werden darf, egal wer den Lauf ausloest.
        if includeDeletes, profile.deleteAllowed, !inventoryComplete {
            throw SyncEngineError.incompleteInventory
        }

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
            skippedBranches: skipped, gitBranches: mirrored, transferPaths: transferPaths
        )
        defer { context.cleanup() }

        let store = remoteFiles(profile, session, context.endpoints)
        // Erst greifen, dann anfassen. Zwei Rechner, die gleichzeitig mit
        // Loeschen hochladen, raeumen sich gegenseitig genau die Dateien weg,
        // die der andere eben geschrieben hat.
        //
        // Kein `defer` fuers Loesen: Das darf nicht abgekoppelt in einem
        // eigenen Task passieren, denn die Sitzung ist dann schon gestoppt und
        // die Sperre bliebe liegen. Geloest wird deshalb von Hand, an jedem
        // der beiden Ausgaenge.
        let held = await claimTarget(store, onLog: onLog)
        if case .taken(let note) = held {
            throw SyncEngineError.targetBusy(note: note)
        }
        func release() async {
            guard case .held = held, let store else { return }
            try? await store.remove(["lock"], under: ".synctool")
        }

        do {
            try await guardTarget(
                profile: profile, direction: direction, includeDeletes: includeDeletes,
                remotePaths: remotePaths, localPaths: localPaths, remote: store, onLog: onLog
            )
        } catch {
            await release()
            throw error
        }

        let gitLimit = gitDeleteLimit(
            mirrored: mirrored, direction: direction,
            remotePaths: remotePaths, localPaths: localPaths, profile: profile
        )
        let mainLimit = deleteLimit(expected: expectedDeletions, profile: profile)
        // Ein Ordner je Lauf, beide Laeufe teilen ihn sich. Wer eine Fassung
        // zurueckholen will, findet alles aus diesem Abgleich an einer Stelle.
        let backupDir = profile.backupKeepDays > 0 ? VersionFolder.path() : nil
        // Nur nachsehen, wenn es darauf ankommt: Ohne Sicherung und ohne
        // Loeschen spielt die Fassung hier keine Rolle, und ein
        // `--version`-Aufruf waere umsonst.
        let backupWhileDeleting: Bool
        if let supportsBackupWhileDeleting {
            backupWhileDeleting = supportsBackupWhileDeleting
        } else if backupDir != nil, includeDeletes, profile.deleteAllowed {
            backupWhileDeleting = !(await RsyncLocator.locate(preferred: rsyncPath)?
                .isOpenRsync ?? true)
        } else {
            backupWhileDeleting = true
        }
        let options = RsyncArguments.Options(
            dryRun: false,
            includeDeletes: includeDeletes,
            remoteShell: context.remoteShell,
            excludeFile: context.excludeFile,
            protectFile: context.protectFile,
            endpoints: context.endpoints,
            flavour: context.flavour,
            gitFilterFile: context.gitFilterFile,
            gitMaxDelete: gitLimit,
            maxDelete: mainLimit,
            backupDir: backupDir,
            supportsBackupWhileDeleting: backupWhileDeleting,
            filesFromFile: context.filesFromFile
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
        ///
        /// Der letzte Abgleich rueckt nur nach einem Lauf vor, der durchlief.
        /// Frueher stand er auch nach einem Abbruch auf jetzt, und damit war
        /// `DriftResolver` blind: Jede Aenderung von vor dem Fehlschlag lag
        /// dann vor dem letzten Abgleich, ein echter beidseitiger Konflikt
        /// wurde nicht mehr als solcher erkannt, und statt einer Rueckfrage
        /// entschied stillschweigend der juengere Zeitstempel.
        ///
        /// Gespeichert wird der Zeitpunkt der Pruefung, nicht der des
        /// Laufendes. Was waehrend der Uebertragung geschrieben wurde, hat
        /// dieser Lauf nicht gesehen; mit `Date()` gaelte es als abgeglichen
        /// und koennte nie mehr ein Konflikt werden. Der Pruefzeitpunkt ist
        /// die vorsichtige Richtung, er erzeugt im Zweifel einen Konflikt zu
        /// viel statt einen zu wenig.
        func record(succeeded: Bool) {
            if succeeded { stateStore.recordSync(for: profile, at: checkedAt ?? Date()) }
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

        if backupDir != nil, includeDeletes, profile.deleteAllowed, !backupWhileDeleting {
            onLog?(
                "Dieser Lauf löscht und sichert deshalb nichts weg: openrsync "
                    + "hört mit Sicherungen still auf zu löschen. "
                    + "Mit `brew install rsync` gibt es beides zusammen."
            )
        }

        // Ein Lauf ohne Inhalt ist kein Fehler: Es kann sein, dass in dieser
        // Richtung nur geloescht wird oder nur ein Repo ansteht.
        let hasContent = transferPaths.map { !$0.isEmpty } ?? true
        let deletes = includeDeletes && profile.deleteAllowed

        var outcome = RsyncOutcome(status: 0, items: [], errorLines: [], statsLines: [])
        do {
            if hasContent {
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
            }

            // Erst der Inhalt, dann das Aufraeumen. Eine umbenannte Datei geht
            // so zuerst unter dem neuen Namen hinueber und faellt danach unter
            // dem alten weg; zu keinem Zeitpunkt fehlt sie auf der Gegenseite.
            //
            // Ein eigener Lauf, sobald es eine Messung gibt. Bewusst nicht an
            // `context.filesFromFile` festgemacht: Steht in dieser Richtung
            // nichts zu uebertragen an, gibt es keine Datei, und der Lauf, der
            // nur aufraeumen soll, fiele stillschweigend aus. Ohne Messung
            // traegt der Lauf darueber sein `--delete` noch selbst, wie frueher.
            if deletes, transferPaths != nil {
                onLog?("Aufräumen")
                let deleteOutcome = try await run(
                    arguments: RsyncArguments.deleteArguments(
                        profile: profile, direction: direction, options: options
                    ),
                    direction: direction,
                    remotePath: profile.remotePath,
                    rsyncPath: rsyncPath,
                    environment: context.environment,
                    onLog: onLog,
                    onLine: report
                )
                outcome = merged(outcome, deleteOutcome)
            }

            // openrsync haelt an `--max-delete` nicht an, es hoert still auf zu
            // loeschen. Nachgezaehlt wird deshalb auch hier und nicht nur im
            // Git-Lauf: sonst meldet ein Lauf, der 5.000 Eintraege wegraeumen
            // wollte und 100 wegraeumte, einen Erfolg, und beide Seiten stehen
            // danach auf einem Mischzustand.
            if deletes, reachedDeleteLimit(outcome, limit: mainLimit) {
                record(succeeded: false)
                throw SyncEngineError.deleteLimit(limit: mainLimit, direction: direction)
            }

            // Danach die Repos. Bricht etwas dazwischen ab,
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
                if reachedDeleteLimit(gitOutcome, limit: gitLimit) {
                    record(succeeded: false)
                    throw SyncEngineError.gitDeleteLimit(limit: gitLimit)
                }
            }
        } catch {
            record(succeeded: false)
            await release()
            throw error
        }

        let geglueckt = outcome.succeeded || outcome.isWarningOnly
        record(succeeded: geglueckt)
        // Den gemeinsamen Stand mitschreiben, damit der naechste Rechner ihn
        // vorfindet. Dieselben Zahlen wie lokal, nur an einem Ort, den alle
        // lesen. Klappt es nicht, bleibt es beim lokalen Stand: Der Lauf hat
        // seine Daten uebertragen, und das ist die Hauptsache.
        if let store {
            // Erst lesen, dann schreiben: Nach einem Fehlschlag darf der
            // letzte Abgleich nicht verschwinden. Stuende dort danach nichts
            // mehr, waere die Konflikterkennung auf allen Rechnern blind, und
            // ein einziger abgebrochener Lauf haette das angerichtet.
            let vorher = SharedState.decoded(
                (await store.read(SharedState.fileName)) ?? Data()
            )
            let stand = SharedState(
                lastSync: geglueckt ? (checkedAt ?? Date()) : vorher?.lastSync,
                lastMachine: SharedState.machineName
            )
            do {
                try await store.write(try stand.encoded(), to: SharedState.fileName)
            } catch {
                onLog?(
                    "Der gemeinsame Stand ließ sich nicht schreiben: "
                        + error.localizedDescription
                )
            }
        }
        // Nur wenn dieser Lauf etwas gesichert haben kann. Eine Sicherung
        // entsteht beim Ersetzen und beim Loeschen, nicht bei einer neuen
        // Datei: Dort ist nichts da, was wegzulegen waere. Ohne neue Sicherung
        // ist auch nichts gewachsen, und die Runde zur Gegenstelle koennte nur
        // Zeit kosten.
        let hatGesichert = outcome.items.contains { $0.kind == .updated || $0.kind == .deleted }
        if backupDir != nil, hatGesichert {
            await sweepVersions(
                profile: profile, direction: direction, remote: store,
                endpoints: context.endpoints, onLog: onLog
            )
        }
        // Als Letztes, wenn nichts mehr auf die Gegenstelle zugreift.
        await release()
        return outcome
    }

    /// Greift die Sperre auf der Gegenstelle.
    ///
    /// `true` heisst: Dieser Lauf hat sie und muss sie wieder loesen. `true`
    /// auch dann, wenn es gar keine Gegenstelle zum Sperren gibt: Ohne Ziel
    /// gibt es nichts, was zwei Laeufe durcheinanderbringen koennten, und ein
    /// Lauf soll nicht daran scheitern.
    ///
    /// Eine liegengebliebene Sperre wird uebernommen. Ein abgestuerzter Lauf
    /// kann seine nicht aufraeumen, und eine Sperre, die niemand mehr loest,
    /// legte das Profil fuer immer still.
    private enum Claim {
        /// Dieser Lauf haelt die Sperre und muss sie wieder loesen.
        case held
        /// Es gibt nichts zu sperren, oder es war nicht nachzusehen.
        case free
        case taken(note: String)
    }

    private func claimTarget(_ store: RemoteFiles?, onLog: ((String) -> Void)?) async -> Claim {
        guard let store else { return .free }

        func note() async -> String {
            (await store.read(SyncLock.directory + "/wer")).map {
                String(decoding: $0, as: UTF8.self)
            } ?? ""
        }
        func mark() async {
            try? await store.write(Data(SyncLock.note().utf8), to: SyncLock.directory + "/wer")
        }

        switch await store.claim(SyncLock.directory) {
        case .claimed:
            await mark()
            return .held
        case .unavailable:
            // Nicht nachzusehen. Scheitert die Verbindung wirklich, faellt
            // gleich darauf der Lauf selbst, und zwar mit einer Meldung, die
            // den Grund nennt.
            return .free
        case .taken:
            let vorhanden = await note()
            guard SyncLock.isStale(vorhanden) else { return .taken(note: vorhanden) }
            onLog?("Eine liegengebliebene Sperre auf dem Ziel wird übernommen.")
            try? await store.remove(["lock"], under: ".synctool")
            guard case .claimed = await store.claim(SyncLock.directory) else {
                return .taken(note: vorhanden)
            }
            await mark()
            return .held
        }
    }

    /// Raeumt Sicherungsordner weg, die aelter sind als das Profil erlaubt.
    ///
    /// Erst nach dem Lauf: Waere der Ordner dieses Laufs schon weg, bevor er
    /// geschrieben ist, fiele die Sicherung aus, fuer die er da ist. Und
    /// bewusst ohne `throws`: Ein Lauf, der die Daten uebertragen hat, gilt
    /// nicht deshalb als gescheitert, weil hinterher ein alter Ordner
    /// stehenblieb. Was nicht klappt, steht im Protokoll.
    ///
    /// Das Alter kommt aus dem Ordnernamen, nicht aus dem Dateisystem. Ueber
    /// ssh gaebe es dafuer ein zweites Kommando, und ein Ordnername, den diese
    /// App geschrieben hat, traegt das Datum ohnehin. Was nicht nach einem
    /// eigenen Ordner aussieht, bleibt liegen.
    private func sweepVersions(
        profile: Profile,
        direction: SyncDirection,
        remote: RemoteFiles?,
        endpoints: SyncEndpoints,
        onLog: ((String) -> Void)?
    ) async {
        guard profile.backupKeepDays > 0 else { return }
        // Gesichert wird auf der Empfaengerseite, also wird dort geraeumt.
        let store: RemoteFiles? =
            direction == .push
            ? remote
            : RemoteStore(backend: .fileSystem(URL(fileURLWithPath: endpoints.local)))
        guard let store else { return }

        let expired = VersionFolder.expired(
            await store.list(VersionFolder.root), keepDays: profile.backupKeepDays
        )
        guard !expired.isEmpty else { return }
        do {
            try await store.remove(expired, under: VersionFolder.root)
            onLog?(
                "\(expired.count) Sicherungsordner älter als "
                    + "\(profile.backupKeepDays) Tage weggeräumt."
            )
        } catch {
            onLog?("Alte Sicherungen ließen sich nicht wegräumen: \(error.localizedDescription)")
        }
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
        remote: RemoteFiles?,
        onLog: ((String) -> Void)?
    ) async throws {
        let source = direction == .push ? localPaths : remotePaths
        let destination = direction == .push ? remotePaths : localPaths
        // Die Kennung liegt im Ziel und wandert nicht mit: `.synctool-ziel`
        // steht in `Profile.systemExcludes`. Damit laesst sich ein Ordner
        // wiedererkennen, und ein Lauf gegen den falschen faellt auf, bevor er
        // etwas anfasst. `nil` heisst: nicht nachzusehen, und daraus wird kein
        // Nein, sonst blockierte jede Stoerung den Lauf.
        var markerFound: Bool?
        if !profile.targetMarkerID.isEmpty, let remote {
            if let daten = await remote.read(TargetMarker.fileName) {
                let gelesen = String(decoding: daten, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                markerFound = gelesen == profile.targetMarkerID
            }
        }
        let facts = TargetFacts(
            direction: direction,
            sourcePathCount: source.count,
            destinationPathCount: destination.count,
            rememberedPathCount: inventoryStore.load(for: profile)?.paths.count ?? 0,
            expectedMarker: profile.targetMarkerID,
            markerFound: markerFound
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
        /// Die Pfade, die der Inhaltslauf uebertragen soll. `nil` heisst:
        /// keine Messung, dann geht der ganze Baum.
        let filesFromFile: String?
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
        gitBranches: [String] = [],
        transferPaths: [String]? = nil
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

        // Die eigenen Ordner zuerst, damit sie auch dann gelten, wenn der
        // Nutzer seine Ausschlussliste leergeraeumt hat. Sie stehen damit auch
        // in den Bestandslaeufen drin: Was die App selbst im Ziel ablegt,
        // gehoert in keine der beiden Bestandszahlen.
        let excludeFile = try RsyncArguments.writeExcludeFile(
            Profile.internalExcludes + profile.excludes,
            branches: skippedBranches, in: directory
        )
        let protectFile = try RsyncArguments.writeProtectFile(protectedPaths, in: directory)
        let gitFilterFile = try RsyncArguments.writeGitFilterFile(
            branches: gitBranches, in: directory
        )
        let filesFromFile = try transferPaths.flatMap {
            try RsyncArguments.writeFilesFromFile($0, in: directory)
        }
        return RunContext(
            remoteShell: remoteShell,
            excludeFile: excludeFile,
            protectFile: protectFile,
            gitFilterFile: gitFilterFile,
            filesFromFile: filesFromFile,
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
