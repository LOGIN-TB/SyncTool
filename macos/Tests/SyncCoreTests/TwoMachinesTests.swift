import Foundation
import Testing

@testable import SyncCore

/// Die eigentliche Abnahme fuer die Frage, die den Umbau ausgeloest hat:
/// Geht zwischen mehreren Rechnern etwas verloren, und kommen alle auf
/// denselben Stand?
///
/// Zwei Stammordner, ein Zielordner, alles im Dateisystem und ohne ssh. Jeder
/// Rechner hat seinen eigenen Zustandsspeicher, so wie in Wirklichkeit.
@Suite("Zwei Rechner, eine Gegenstelle")
struct TwoMachinesTests {
    private struct Bench {
        let base: URL
        let box: URL
        let a: URL
        let b: URL
        let supportA: URL
        let supportB: URL
    }

    private func makeBench() throws -> Bench {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-zwei-\(UUID().uuidString)")
        let bench = Bench(
            base: base,
            box: base.appendingPathComponent("box"),
            a: base.appendingPathComponent("a"),
            b: base.appendingPathComponent("b"),
            supportA: base.appendingPathComponent("supportA"),
            supportB: base.appendingPathComponent("supportB")
        )
        for url in [bench.box, bench.a, bench.b, bench.supportA, bench.supportB] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return bench
    }

    private func profile(_ root: URL, box: URL) -> Profile {
        Profile(
            localRoot: root.path,
            remotePath: box.path,
            authMode: .password,
            excludes: [],
            deleteAllowed: true,
            backupKeepDays: 30,
            transport: .localFolder
        )
    }

    private func engine(_ support: URL, base: URL) -> SyncEngine {
        SyncEngine(
            runner: RsyncRunner(),
            stateStore: SyncStateStore(url: support.appendingPathComponent("state.json")),
            inventoryStore: InventoryStore(directory: support),
            knownHosts: support.appendingPathComponent("known_hosts"),
            identity: support.appendingPathComponent("id_ed25519"),
            workspaceParent: base
        )
    }

    private func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
        )
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Prueft und uebertraegt, so wie es das Statusfenster tut: mit der
    /// gemessenen Pfadliste und den Schutzregeln.
    @discardableResult
    private func sync(
        _ engine: SyncEngine, _ profile: Profile, _ direction: SyncDirection,
        deletes: Bool = false
    ) async throws -> SyncStatus {
        let status = try await engine.check(
            profile: profile, password: nil, rsyncPath: TestRsync.systemRsync,
            supportsChecksumField: false
        )
        _ = try await engine.transfer(
            profile: profile, password: nil, direction: direction,
            includeDeletes: deletes,
            expectedDeletions: deletes
                ? (direction == .pull
                    ? status.deletionsOnPull.count : status.deletionsOnPush.count)
                : nil,
            protectedPaths: deletes
                ? (direction == .pull ? status.protectedOnPull : status.protectedOnPush) : [],
            expectedItems: status.itemCount(for: direction),
            gitUnits: status.gitUnits,
            remotePaths: status.remotePaths, localPaths: status.localPaths,
            checkedAt: status.checkedAt,
            rsyncPath: TestRsync.systemRsync,
            inventoryComplete: status.inventoryComplete,
            transferPaths: status.transferPaths(for: direction)
        )
        return status
    }

    /// Szenario 1: Jeder arbeitet an seiner Datei. Danach hat jeder beide.
    @Test("Arbeit an verschiedenen Dateien geht nirgends verloren")
    func workOnDifferentFilesSurvives() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileA = profile(bench.a, box: bench.box)
        let profileB = profile(bench.b, box: bench.box)
        let engineA = engine(bench.supportA, base: bench.base)
        let engineB = engine(bench.supportB, base: bench.base)

        try write("von A", to: bench.a.appendingPathComponent("a.txt"))
        try await sync(engineA, profileA, .push)

        try write("von B", to: bench.b.appendingPathComponent("b.txt"))
        try await sync(engineB, profileB, .push)
        try await sync(engineB, profileB, .pull)
        try await sync(engineA, profileA, .pull)

        for ordner in [bench.a, bench.b, bench.box] {
            #expect(try text(ordner.appendingPathComponent("a.txt")) == "von A")
            #expect(try text(ordner.appendingPathComponent("b.txt")) == "von B")
        }
    }

    /// Szenario 2: Beide aendern dieselbe Datei. Keine der beiden Fassungen
    /// darf verschwinden, in keiner Richtung.
    @Test("Bei beidseitiger Arbeit überlebt jede Fassung")
    func bothVersionsSurviveAConflict() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileA = profile(bench.a, box: bench.box)
        let profileB = profile(bench.b, box: bench.box)
        let engineA = engine(bench.supportA, base: bench.base)
        let engineB = engine(bench.supportB, base: bench.base)

        try write("gemeinsam", to: bench.a.appendingPathComponent("streit.txt"), age: 7200)
        try await sync(engineA, profileA, .push)
        try await sync(engineB, profileB, .pull)

        // Der letzte Abgleich liegt eine Stunde zurück. Im Test passiert alles
        // in derselben Sekunde, und dann entschiede der Zeitvergleich über
        // etwas, das er in Wirklichkeit nie zu sehen bekommt.
        let vorEinerStunde = Date().addingTimeInterval(-3600)
        for support in [bench.supportA, bench.supportB] {
            SyncStateStore(url: support.appendingPathComponent("state.json"))
                .recordSync(for: profileA, at: vorEinerStunde)
            SyncStateStore(url: support.appendingPathComponent("state.json"))
                .recordSync(for: profileB, at: vorEinerStunde)
        }

        // Beide fassen sie danach an, A etwas früher als B.
        try write("A hat gearbeitet", to: bench.a.appendingPathComponent("streit.txt"), age: 600)
        try write("B hat auch gearbeitet", to: bench.b.appendingPathComponent("streit.txt"))

        try await sync(engineA, profileA, .push)
        let statusB = try await sync(engineB, profileB, .push)

        // B sieht den Konflikt und fasst ihn nicht an.
        #expect(statusB.conflicts.map(\.path) == ["streit.txt"])
        #expect(try text(bench.b.appendingPathComponent("streit.txt")) == "B hat auch gearbeitet")
        #expect(try text(bench.box.appendingPathComponent("streit.txt")) == "A hat gearbeitet")

        // Und auch beim Herunterladen bleibt Bs Fassung stehen.
        try await sync(engineB, profileB, .pull)
        #expect(try text(bench.b.appendingPathComponent("streit.txt")) == "B hat auch gearbeitet")
    }

    /// Szenario 3: A loescht, B prueft. B darf die Datei nicht wiederbeleben.
    @Test("Eine Löschung von A wird von B nicht rückgängig gemacht")
    func aDeletionIsNotUndoneByTheOtherMachine() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileA = profile(bench.a, box: bench.box)
        let profileB = profile(bench.b, box: bench.box)
        let engineA = engine(bench.supportA, base: bench.base)
        let engineB = engine(bench.supportB, base: bench.base)

        try write("weg damit", to: bench.a.appendingPathComponent("weg.txt"))
        try write("bleibt", to: bench.a.appendingPathComponent("bleibt.txt"))
        try await sync(engineA, profileA, .push)
        try await sync(engineB, profileB, .pull)
        #expect(exists(bench.b.appendingPathComponent("weg.txt")))

        // A löscht und lädt mit Löschen hoch.
        try FileManager.default.removeItem(at: bench.a.appendingPathComponent("weg.txt"))
        try await sync(engineA, profileA, .push, deletes: true)
        #expect(!exists(bench.box.appendingPathComponent("weg.txt")))

        // B sieht die Löschung, statt die Datei wieder hochzuladen.
        let statusB = try await sync(engineB, profileB, .pull)
        #expect(statusB.deletionsOnPull.map(\.path) == ["weg.txt"])
        #expect(statusB.outgoing.isEmpty)
        #expect(!exists(bench.box.appendingPathComponent("weg.txt")))

        // Und mit Löschen räumt B sie auch bei sich weg.
        try await sync(engineB, profileB, .pull, deletes: true)
        #expect(!exists(bench.b.appendingPathComponent("weg.txt")))
        #expect(exists(bench.b.appendingPathComponent("bleibt.txt")))
    }

    /// Szenario 4: Nach einem Abbruch behauptet kein Bestand mehr, als
    /// angekommen ist, und der letzte Abgleich steht noch auf dem alten Wert.
    @Test("Ein abgebrochener Lauf rückt nichts vor")
    func anAbortedRunAdvancesNothing() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileA = profile(bench.a, box: bench.box)
        let stateStore = SyncStateStore(
            url: bench.supportA.appendingPathComponent("state.json")
        )
        let inventoryStore = InventoryStore(directory: bench.supportA)

        try write("eins", to: bench.a.appendingPathComponent("eins.txt"))
        try await sync(engine(bench.supportA, base: bench.base), profileA, .push)
        let nachErfolg = stateStore.load().lastSync(for: profileA)
        let bestand = inventoryStore.load(for: profileA)?.paths
        #expect(nachErfolg != nil)

        // Ein Lauf, der scheitert: das Ziel gibt es nicht mehr.
        var kaputt = profileA
        kaputt.remotePath = bench.base.appendingPathComponent("gibtsnicht").path
        _ = try? await engine(bench.supportA, base: bench.base).transfer(
            profile: kaputt, password: nil, direction: .pull,
            includeDeletes: false, expectedItems: 1,
            rsyncPath: TestRsync.systemRsync, transferPaths: ["eins.txt"]
        )

        #expect(stateStore.load().lastSync(for: profileA) == nachErfolg)
        // Der Bestand ist danach höchstens vorsichtiger, nie großzügiger.
        let danach = inventoryStore.load(for: profileA)?.paths ?? []
        #expect(danach.isSubset(of: bestand ?? []))
    }

    /// Die Sperre: Zwei Läufe gleichzeitig räumen sich gegenseitig genau die
    /// Dateien weg, die der andere eben geschrieben hat.
    @Test("Läuft schon einer, startet der zweite nicht")
    func aSecondRunIsRefusedWhileTheFirstHolds() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileB = profile(bench.b, box: bench.box)

        // So sieht es aus, während ein anderer Rechner läuft.
        let store = try #require(
            RemoteStore.make(
                profile: profileB, session: nil,
                endpoints: SyncEndpoints.resolve(profile: profileB)
            )
        )
        #expect(await store.claim(SyncLock.directory) == .claimed)
        try await store.write(Data(SyncLock.note().utf8), to: SyncLock.directory + "/wer")

        try write("von B", to: bench.b.appendingPathComponent("b.txt"))
        await #expect(throws: SyncEngineError.self) {
            _ = try await self.engine(bench.supportB, base: bench.base).transfer(
                profile: profileB, password: nil, direction: .push,
                includeDeletes: false, expectedItems: 1,
                rsyncPath: TestRsync.systemRsync, transferPaths: ["b.txt"]
            )
        }
        #expect(!exists(bench.box.appendingPathComponent("b.txt")))

        // Ist sie wieder frei, läuft es durch.
        try await store.remove(["lock"], under: ".synctool")
        _ = try await engine(bench.supportB, base: bench.base).transfer(
            profile: profileB, password: nil, direction: .push,
            includeDeletes: false, expectedItems: 1,
            rsyncPath: TestRsync.systemRsync, transferPaths: ["b.txt"]
        )
        #expect(try text(bench.box.appendingPathComponent("b.txt")) == "von B")
    }

    /// Weder Sperre noch gemeinsamer Stand duerfen im Abgleich auftauchen.
    /// Sonst laege auf jedem Rechner eine Kopie der Sperre.
    @Test("Die eigenen Dateien der App bleiben im Ziel")
    func theAppsOwnFilesStayOnTheTarget() async throws {
        let bench = try makeBench()
        defer { try? FileManager.default.removeItem(at: bench.base) }
        let profileA = profile(bench.a, box: bench.box)
        let engineA = engine(bench.supportA, base: bench.base)

        try write("eins", to: bench.a.appendingPathComponent("eins.txt"))
        try await sync(engineA, profileA, .push)
        #expect(exists(bench.box.appendingPathComponent(SharedState.fileName)))

        let status = try await sync(engineA, profileA, .pull)
        #expect(!exists(bench.a.appendingPathComponent(".synctool")))
        #expect(!status.remotePaths.contains { $0.hasPrefix(".synctool") })
        #expect(status.deletionsOnPush.isEmpty)
    }
}
