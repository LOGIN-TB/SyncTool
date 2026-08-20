import Foundation
import Testing

@testable import SyncCore

/// Nimmt die Aufrufe entgegen, statt rsync zu starten.
private final class FakeRunner: RsyncExecuting, @unchecked Sendable {
    var plans: [RsyncPlan] = []
    var outcomes: [RsyncOutcome] = []
    var lines: [String] = []
    /// Ausgabe je Lauf, in der Reihenfolge der Aufrufe. Die Bestandslaeufe
    /// liefern ihr Ergebnis ueber die Zeilen, nicht ueber `outcomes`.
    var linesPerRun: [[String]] = []
    var cancelled = false
    /// Inhalt der Schutzdatei je Lauf. Die liegt im Temp-Ordner der SSH-Sitzung
    /// und ist nach dem Lauf weg, deshalb hier beim Aufruf mitlesen.
    var protectContents: [String] = []

    func execute(_ plan: RsyncPlan, onLine: ((String) -> Void)?) async throws -> RsyncOutcome {
        plans.append(plan)
        if let argument = plan.arguments.first(where: { $0.hasPrefix("--filter=merge ") }) {
            let path = String(argument.dropFirst("--filter=merge ".count))
            protectContents.append((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        }
        for line in lines { onLine?(line) }
        if !linesPerRun.isEmpty {
            for line in linesPerRun.removeFirst() { onLine?(line) }
        }
        guard !outcomes.isEmpty else {
            return RsyncOutcome(status: 0, items: [], errorLines: [], statsLines: [])
        }
        return outcomes.removeFirst()
    }

    func cancel() { cancelled = true }
}

@Suite("SyncEngine")
final class SyncEngineTests {
    private let sandbox: URL
    private let localRoot: URL
    private let support: URL
    private let runner = FakeRunner()
    private let engine: SyncEngine
    private let inventoryStore: InventoryStore
    private var profile: Profile

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-tests-\(UUID().uuidString)")
        localRoot = sandbox.appendingPathComponent("local")
        support = sandbox.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        inventoryStore = InventoryStore(directory: support)
        engine = SyncEngine(
            runner: runner,
            stateStore: SyncStateStore(url: support.appendingPathComponent("state.json")),
            inventoryStore: inventoryStore,
            knownHosts: support.appendingPathComponent("known_hosts"),
            identity: support.appendingPathComponent("id_ed25519")
        )
        profile = Profile(
            localRoot: localRoot.path,
            host: "example.org",
            port: 23,
            user: "u1",
            remotePath: "dev",
            // Key-Modus, damit kein Passwort-Socket noetig ist.
            authMode: .publicKey
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func outcome(_ items: [ChangeItem], status: Int32 = 0) -> RsyncOutcome {
        RsyncOutcome(status: status, items: items, errorLines: [], statsLines: [])
    }

    /// Eine Zeile, wie sie ein Bestandslauf ausgibt.
    private func line(_ path: String, offset: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd-HH:mm:ss"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: 1_770_000_000 + offset))
        return ">f+++++++++|10|\(stamp)|\(path)|"
    }

    private func item(
        _ path: String, offset: TimeInterval, kind: ChangeKind = .updated
    ) -> ChangeItem {
        ChangeItem(
            path: path,
            kind: kind,
            type: .file,
            size: 10,
            modified: Date(timeIntervalSince1970: 1_770_000_000 + offset),
            flags: ">f.st....."
        )
    }

    /// Zwei Bestandslaeufe plus der lokale Vergleichslauf fuer die
    /// Ausschluesse. Nur der erste geht ueber die Leitung.
    @Test("Prüfen listet beide Seiten auf und kostet eine einzige Anmeldung")
    func checkListsBothSides() async throws {
        _ = try await engine.check(profile: profile, password: nil, rsyncPath: "/usr/bin/rsync")

        #expect(runner.plans.count == 3)
        #expect(runner.plans.allSatisfy { $0.arguments.contains("--dry-run") })
        #expect(runner.plans[0].arguments.dropLast().last == "u1@example.org:dev/")
        #expect(runner.plans[1].arguments.dropLast().last == localRoot.path + "/")
        #expect(runner.plans[2].arguments.dropLast().last == localRoot.path + "/")
        // Nur der Fernlauf braucht ssh.
        #expect(runner.plans.filter { $0.arguments.contains("-e") }.count == 1)
    }

    @Test("Ein Bestandslauf fasst unter keinen Umständen etwas an")
    func inventoryRunsNeverTouchAnything() async throws {
        profile.deleteAllowed = true
        _ = try await engine.check(profile: profile, password: nil, rsyncPath: "/usr/bin/rsync")

        #expect(runner.plans.allSatisfy { !$0.arguments.contains("--delete") })
        #expect(runner.plans.allSatisfy { !$0.arguments.contains("--partial") })
        #expect(
            runner.plans.allSatisfy { !$0.arguments.contains { $0.hasPrefix("--max-delete") } }
        )
    }

    @Test("Das Ergebnis wird nach Zeitstempel einsortiert")
    func checkClassifiesByTimestamp() async throws {
        runner.linesPerRun = [
            [line("a.txt", offset: 600), line("nur-remote.txt", offset: 0)],
            [line("a.txt", offset: 0)],
            [line("a.txt", offset: 0)],
        ]
        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )

        #expect(Set(status.incoming.map(\.path)) == ["a.txt", "nur-remote.txt"])
        #expect(status.outgoing.isEmpty)
        #expect(status.conflicts.isEmpty)
        #expect(!status.isInSync)
    }

    /// Die Antwort auf "warum sehe ich im FTP-Client mehr Dateien".
    @Test("Was die Ausschlussliste verdeckt, steht im Ergebnis")
    func checkReportsWhatTheExcludesHide() async throws {
        profile.excludes = [".DS_Store"]
        runner.linesPerRun = [
            [line("a.txt", offset: 0)],
            [line("a.txt", offset: 0)],
            [line("a.txt", offset: 0), line(".DS_Store", offset: 0)],
        ]
        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        #expect(status.isInSync)
        #expect(status.report.excluded.map(\.path) == [".DS_Store"])
        #expect(status.report.remoteFiles == 1)
        #expect(status.report.localFiles == 1)
    }

    @Test("Ohne Ausschlüsse entfällt der Vergleichslauf")
    func withoutExcludesThereIsNoComparisonRun() async throws {
        profile.excludes = []
        _ = try await engine.check(profile: profile, password: nil, rsyncPath: "/usr/bin/rsync")
        #expect(runner.plans.count == 2)
    }

    @Test("Prüfsummen nur mit rsync 3.x, openrsync kennt das Feld nicht")
    func checksumFieldOnlyForRsync3() async throws {
        profile.useChecksum = true

        _ = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync",
            supportsChecksumField: false
        )
        #expect(runner.plans.allSatisfy { !$0.arguments.contains("--checksum") })

        runner.plans.removeAll()
        _ = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync",
            supportsChecksumField: true
        )
        // Der Vergleichslauf fuer die Ausschluesse braucht keine Pruefsummen.
        #expect(runner.plans.prefix(2).allSatisfy { $0.arguments.contains("--checksum") })
    }

    @Test("Der Fortschritt zählt übertragene Dateien, nicht Ausgabezeilen")
    func transferReportsProgressPerItem() async throws {
        runner.lines = [
            ">f.st.....|10|2026/08/16-12:00:00|eins.txt",
            "sending incremental file list",
            ">f.st.....|10|2026/08/16-12:00:00|zwei.txt",
        ]
        runner.outcomes = [outcome([])]

        var seen: [TransferProgress] = []
        _ = try await engine.transfer(
            profile: profile,
            password: nil,
            direction: .push,
            includeDeletes: false,
            expectedItems: 2,
            rsyncPath: "/usr/bin/rsync",
            onProgress: { seen.append($0) }
        )

        #expect(seen.count == 2)
        #expect(seen.last?.completed == 2)
        #expect(seen.last?.currentPath == "zwei.txt")
        #expect(seen.last?.fraction == 1.0)
    }

    @Test("Nach der Übertragung steht der Zeitpunkt fest")
    func transferRecordsTheSyncTime() async throws {
        let store = SyncStateStore(url: support.appendingPathComponent("state.json"))
        let engine = SyncEngine(
            runner: runner,
            stateStore: store,
            knownHosts: support.appendingPathComponent("known_hosts"),
            identity: support.appendingPathComponent("id_ed25519")
        )
        #expect(store.load().lastSync(for: profile) == nil)

        runner.outcomes = [outcome([])]
        _ = try await engine.transfer(
            profile: profile, password: nil, direction: .push,
            includeDeletes: false, expectedItems: 0, rsyncPath: "/usr/bin/rsync"
        )
        #expect(store.load().lastSync(for: profile) != nil)
    }

    // MARK: - Bestandsliste

    /// Der Datenverlust-Pfad: Frueher landete der komplette lokale Baum im
    /// Bestand, auch nach einem reinen Herunterladen. Eine nur lokal
    /// existierende Datei galt danach als "auf dem Server geloescht".
    @Test("Nur der gemeinsame Bestand wird fortgeschrieben")
    func transferRecordsOnlyTheCommonInventory() async throws {
        runner.outcomes = [outcome([])]
        _ = try await engine.transfer(
            profile: profile, password: nil, direction: .pull,
            includeDeletes: false, expectedItems: 0,
            remotePaths: ["vom-server.txt"], localPaths: ["nur-hier.txt"],
            rsyncPath: "/usr/bin/rsync"
        )

        let paths = try #require(inventoryStore.load(for: profile)?.paths)
        #expect(paths.contains("vom-server.txt"))
        #expect(!paths.contains("nur-hier.txt"))
        #expect(inventoryStore.load(for: profile)?.isTrustworthy == true)
    }

    @Test("Die Bestandsliste entscheidet beim Prüfen über die Richtung")
    func inventoryDecidesDirectionOnCheck() async throws {
        inventoryStore.record(for: profile, commonPaths: ["weg.txt"])
        runner.linesPerRun = [[line("weg.txt", offset: 0)], [], []]

        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        #expect(status.incoming.isEmpty)
        #expect(status.deletionsOnPush.map(\.path) == ["weg.txt"])
    }

    /// Alte Bestandslisten enthalten Pfade, die nie auf dem Server lagen.
    /// Beim ersten Pruefen werden sie an der Fernseite geradegezogen.
    @Test("Ein Bestand aus der alten Version heilt beim Prüfen")
    func legacyInventoryHealsOnCheck() async throws {
        inventoryStore.save(
            SyncInventory(paths: ["gemeinsam.txt", "nie-hochgeladen.txt"], schema: nil),
            for: profile
        )
        runner.linesPerRun = [
            [line("gemeinsam.txt", offset: 0)],
            [line("gemeinsam.txt", offset: 0), line("nie-hochgeladen.txt", offset: 0)],
            [],
        ]

        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync",
            supportsChecksumField: true
        )
        // Vor der Heilung stuende die Datei unter "auf dem Server geloescht".
        #expect(status.outgoing.map(\.path) == ["nie-hochgeladen.txt"])
        #expect(status.deletionsOnPull.isEmpty)
        #expect(inventoryStore.load(for: profile)?.paths == ["gemeinsam.txt"])
    }

    // MARK: - Schutzregeln

    @Test("Geschützte Pfade erreichen rsync nur zusammen mit --delete")
    func protectedPathsReachRsync() async throws {
        var profileWithDelete = profile
        profileWithDelete.deleteAllowed = true

        runner.outcomes = [outcome([])]
        _ = try await engine.transfer(
            profile: profileWithDelete, password: nil, direction: .push,
            includeDeletes: true, protectedPaths: ["neu-auf-dem-server.txt"],
            expectedItems: 0, rsyncPath: "/usr/bin/rsync"
        )
        #expect(
            runner.plans.last?.arguments.contains { $0.hasPrefix("--filter=merge ") } == true
        )
        #expect(runner.protectContents == ["P /neu-auf-dem-server.txt\n"])

        runner.plans.removeAll()
        runner.outcomes = [outcome([])]
        _ = try await engine.transfer(
            profile: profileWithDelete, password: nil, direction: .push,
            includeDeletes: false, protectedPaths: ["neu-auf-dem-server.txt"],
            expectedItems: 0, rsyncPath: "/usr/bin/rsync"
        )
        #expect(runner.plans.last?.arguments.contains { $0.hasPrefix("--filter") } == false)
    }

    // MARK: - Absturzsicherung

    /// Der gefaehrliche Fall: der Stammordner liegt auf einer Platte, die
    /// gerade nicht angesteckt ist. Ohne diese Sperre raeumte `--delete` die
    /// Gegenseite aus.
    @Test("Eine leere Quelle bricht das Löschen ab, bevor rsync startet")
    func emptySourceStopsDeletingTransfer() async throws {
        var profileWithDelete = profile
        profileWithDelete.deleteAllowed = true
        inventoryStore.record(
            for: profileWithDelete,
            commonPaths: Set((0..<40).map { "datei-\($0).txt" })
        )

        runner.outcomes = [outcome([])]
        await #expect(throws: TargetGuardError.self) {
            _ = try await engine.transfer(
                profile: profileWithDelete, password: nil, direction: .push,
                includeDeletes: true, expectedItems: 0,
                remotePaths: ["datei-0.txt"], localPaths: [],
                rsyncPath: "/usr/bin/rsync"
            )
        }
        #expect(runner.plans.isEmpty)
    }

    @Test("Dieselbe Lage ohne Löschen läuft durch")
    func emptySourceWithoutDeleteRuns() async throws {
        inventoryStore.record(
            for: profile, commonPaths: Set((0..<40).map { "datei-\($0).txt" })
        )

        runner.outcomes = [outcome([])]
        _ = try await engine.transfer(
            profile: profile, password: nil, direction: .push,
            includeDeletes: false, expectedItems: 0,
            remotePaths: ["datei-0.txt"], localPaths: [],
            rsyncPath: "/usr/bin/rsync"
        )
        #expect(runner.plans.count == 1)
    }

    @Test("Ein Fehlerstatus schlägt durch")
    func failingRunThrows() async throws {
        runner.outcomes = [
            RsyncOutcome(
                status: 12, items: [],
                errorLines: ["rsync: connection unexpectedly closed"], statsLines: []
            )
        ]
        await #expect(throws: RsyncError.self) {
            _ = try await self.engine.check(
                profile: self.profile, password: nil, rsyncPath: "/usr/bin/rsync"
            )
        }
    }

    /// Status 24 heisst nur: waehrend des Laufs sind Quelldateien verschwunden.
    /// In einem Dev-Ordner passiert das staendig.
    @Test("Verschwundene Quelldateien gelten nicht als Fehler")
    func vanishedSourceFilesAreTolerated() async throws {
        runner.outcomes = [outcome([], status: 24), outcome([], status: 24)]
        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: "/usr/bin/rsync"
        )
        #expect(status.isInSync)
    }

    @Test("Fehlender Zielordner bekommt eine eigene Meldung")
    func missingRemoteDirectoryGetsItsOwnMessage() async throws {
        runner.outcomes = [
            RsyncOutcome(
                status: 23, items: [],
                errorLines: ["rsync: change_dir \"dev\" failed: No such file or directory (2)"],
                statsLines: []
            )
        ]
        await #expect(throws: SyncEngineError.self) {
            _ = try await self.engine.check(
                profile: self.profile, password: nil, rsyncPath: "/usr/bin/rsync"
            )
        }
    }

    @Test("Ein unvollständiges Profil startet gar keinen Prozess")
    func invalidProfileIsRejectedEarly() async throws {
        profile.host = ""
        await #expect(throws: SyncEngineError.self) {
            _ = try await self.engine.check(
                profile: self.profile, password: nil, rsyncPath: "/usr/bin/rsync"
            )
        }
        #expect(runner.plans.isEmpty)
    }

    @Test("Ausschlüsse erreichen rsync als Datei")
    func excludesReachRsyncAsAFile() async throws {
        profile.excludes = ["node_modules/", ".DS_Store"]
        runner.outcomes = [outcome([]), outcome([])]
        _ = try await engine.check(profile: profile, password: nil, rsyncPath: "/usr/bin/rsync")

        let argument = try #require(
            runner.plans.first?.arguments.first { $0.hasPrefix("--exclude-from=") }
        )
        // Die Datei liegt im temporaeren Sitzungsordner und ist nach dem Lauf weg.
        #expect(argument.hasSuffix("/excludes"))
    }

    @Test("Das Passwort steht nicht in der Kommandozeile")
    func passwordNeverAppearsInTheCommandLine() async throws {
        runner.outcomes = [outcome([]), outcome([])]
        _ = try await engine.check(
            profile: profile, password: "geheim123", rsyncPath: "/usr/bin/rsync"
        )
        #expect(runner.plans.allSatisfy { !$0.displayCommand.contains("geheim123") })
    }
}
