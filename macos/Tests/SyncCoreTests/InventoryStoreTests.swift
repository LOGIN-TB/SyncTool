import Foundation
import Testing

@testable import SyncCore

@Suite("Bestandsliste")
final class InventoryStoreTests {
    private let sandbox: URL
    private let localRoot: URL
    private let store: InventoryStore
    private let profile: Profile

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-inventory-\(UUID().uuidString)")
        localRoot = sandbox.appendingPathComponent("local")
        try FileManager.default.createDirectory(
            at: localRoot.appendingPathComponent("unter"), withIntermediateDirectories: true
        )
        store = InventoryStore(directory: sandbox.appendingPathComponent("support"))
        profile = Profile(localRoot: localRoot.path, host: "example.org", user: "u1")
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @Test("Sichern und Laden übersteht den Umweg über die Datei")
    func saveAndLoadRoundTrip() {
        #expect(store.load(for: profile) == nil)
        store.save(SyncInventory(paths: ["a.txt", "b/"]), for: profile)
        #expect(store.load(for: profile)?.paths == ["a.txt", "b/"])
        store.remove(for: profile)
        #expect(store.load(for: profile) == nil)
    }

    // MARK: - Fortschreibung

    /// Der Fall, der die Fortschreibung von einem simplen Neuschreiben trennt:
    /// Wer hochlaedt, ohne die Loeschungen mitzuziehen, hat die Datei weiterhin
    /// auf dem Server. Faellt sie hier raus, gilt sie beim naechsten Pruefen
    /// wieder als Neuzugang von dort.
    @Test("Hochladen ohne Löschen behält, was nur noch auf dem Server liegt")
    func pushWithoutDeleteKeepsRemoteOnlyPaths() {
        let paths = SyncInventory.afterTransfer(
            previous: ["weg.txt", "bleibt.txt"],
            remote: ["weg.txt", "bleibt.txt"],
            local: ["bleibt.txt", "neu.txt"],
            direction: .push,
            includeDeletes: false,
            succeeded: true
        )
        #expect(paths == ["weg.txt", "bleibt.txt", "neu.txt"])
    }

    @Test("Hochladen mit Löschen macht den lokalen Bestand zum Maßstab")
    func pushWithDeleteMirrorsLocal() {
        let paths = SyncInventory.afterTransfer(
            previous: ["weg.txt", "bleibt.txt"],
            remote: ["weg.txt", "bleibt.txt"],
            local: ["bleibt.txt", "neu.txt"],
            direction: .push,
            includeDeletes: true,
            succeeded: true
        )
        #expect(paths == ["bleibt.txt", "neu.txt"])
    }

    @Test("Herunterladen ohne Löschen behält, was nur noch hier liegt")
    func pullWithoutDeleteKeepsLocalOnlyPaths() {
        let paths = SyncInventory.afterTransfer(
            previous: ["weg.txt", "bleibt.txt"],
            remote: ["bleibt.txt", "neu.txt"],
            local: ["weg.txt", "bleibt.txt"],
            direction: .pull,
            includeDeletes: false,
            succeeded: true
        )
        #expect(paths == ["weg.txt", "bleibt.txt", "neu.txt"])
    }

    @Test("Herunterladen mit Löschen macht den Serverbestand zum Maßstab")
    func pullWithDeleteMirrorsRemote() {
        let paths = SyncInventory.afterTransfer(
            previous: ["weg.txt"],
            remote: ["bleibt.txt"],
            local: ["weg.txt"],
            direction: .pull,
            includeDeletes: true,
            succeeded: true
        )
        #expect(paths == ["bleibt.txt"])
    }

    /// Nach einem abgebrochenen Lauf ist unbekannt, was wirklich drüben ankam.
    /// Die Schnittmenge ist die einzige Aussage, die sicher stimmt.
    @Test("Ein gescheiterter Lauf fällt auf die Schnittmenge zurück")
    func failedTransferFallsBackToTheIntersection() {
        let paths = SyncInventory.afterTransfer(
            previous: ["alt.txt"],
            remote: ["beide.txt", "nur-remote.txt"],
            local: ["beide.txt", "nur-lokal.txt"],
            direction: .push,
            includeDeletes: false,
            succeeded: false
        )
        #expect(paths == ["beide.txt"])
    }

    /// Der eigentliche Fehler: Frueher wanderte der komplette lokale Baum in
    /// den Bestand, auch Dateien, die nie auf dem Server waren. Beim naechsten
    /// Pruefen galten die als "auf dem Server geloescht" und verschwanden bei
    /// einem Herunterladen mit Loeschen.
    @Test("Eine nie hochgeladene Datei kommt nicht in den gemeinsamen Bestand")
    func neverUploadedFileStaysOutOfTheInventory() {
        let paths = SyncInventory.afterTransfer(
            previous: [],
            remote: ["vom-server.txt"],
            local: ["nur-hier.txt"],
            direction: .pull,
            includeDeletes: false,
            succeeded: true
        )
        #expect(!paths.contains("nur-hier.txt"))
        #expect(paths.contains("vom-server.txt"))
    }

    // MARK: - Alte Bestände

    @Test("Ein Bestand aus der alten Version gilt nicht als belastbar")
    func legacyInventoryIsNotTrustworthy() {
        #expect(SyncInventory(paths: ["a"], schema: nil).isTrustworthy == false)
        #expect(SyncInventory(paths: ["a"]).isTrustworthy)
    }

    /// Was im alten Bestand steht, aber nicht auf dem Server liegt, war nie
    /// gemeinsamer Bestand. Genau diese Eintraege haben Dateien verschluckt.
    @Test("Ein alter Bestand wird an der Fernseite geradegezogen")
    func legacyInventoryIsHealedAgainstTheRemoteSide() {
        store.save(
            SyncInventory(paths: ["gemeinsam.txt", "nie-hochgeladen.txt"], schema: nil),
            for: profile
        )
        let trusted = store.trustedPaths(for: profile, remotePaths: ["gemeinsam.txt"])
        #expect(trusted == ["gemeinsam.txt"])
        // Und zwar dauerhaft, nicht nur fuer diesen Aufruf.
        #expect(store.load(for: profile)?.isTrustworthy == true)
        #expect(store.load(for: profile)?.paths == ["gemeinsam.txt"])
    }

    @Test("Ohne Bestand gibt es keine Ersatzantwort")
    func withoutAnInventoryThereIsNoGuess() {
        #expect(store.trustedPaths(for: profile, remotePaths: ["a.txt"]) == nil)
    }

    @Test("Ein belastbarer Bestand wird unverändert durchgereicht")
    func trustworthyInventoryPassesThrough() {
        store.record(for: profile, commonPaths: ["a.txt", "b/"])
        #expect(store.trustedPaths(for: profile, remotePaths: []) == ["a.txt", "b/"])
    }
}

@Suite("Ausgeschlossene Zweige")
struct ExcludedBranchTests {
    /// Der reale Fall: 244.196 ausgeschlossene Pfade unter 45 Zweigen. Einzeln
    /// aufgelistet beantwortet das keine Frage, gruppiert sofort.
    @Test("Ein Ordner schluckt alles unter sich")
    func directorySwallowsItsChildren() {
        let branches = ExcludedBranch.group([
            "a/node_modules/",
            "a/node_modules/paket/",
            "a/node_modules/paket/index.js",
            "b/dist/",
            "b/dist/app.js",
            ".DS_Store",
        ])
        #expect(branches.map(\.path) == ["a/node_modules/", "b/dist/", ".DS_Store"])
        #expect(branches.map(\.count) == [3, 2, 1])
    }

    /// Ohne Schrägstrich ist es kein Verzeichnis und darf nichts einsammeln,
    /// sonst verschluckt "a.txt" ein "a.txt.bak".
    @Test("Eine Datei sammelt nichts ein")
    func fileCollectsNothing() {
        let branches = ExcludedBranch.group(["a.txt", "a.txt.bak"])
        #expect(branches.count == 2)
        #expect(branches.allSatisfy { $0.count == 1 })
    }

    @Test("Ohne Ausschlüsse bleibt die Liste leer")
    func emptyStaysEmpty() {
        #expect(ExcludedBranch.group([]).isEmpty)
    }
}
