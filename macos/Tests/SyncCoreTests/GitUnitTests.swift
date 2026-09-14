import Foundation
import Testing

@testable import SyncCore

@Suite("Git-Repos als Einheit")
struct GitUnitTests {
    private let base = Date(timeIntervalSince1970: 1_770_000_000)

    private func entry(
        _ path: String, type: ItemType = .file, size: Int64 = 100, offset: TimeInterval = 0
    ) -> InventoryEntry {
        InventoryEntry(
            path: path, type: type, size: size, modified: base.addingTimeInterval(offset)
        )
    }

    private func side(_ entries: [InventoryEntry]) -> SideInventory {
        InventoryBuilder.build(from: entries)
    }

    private func resolve(
        remote: [InventoryEntry] = [],
        local: [InventoryEntry] = [],
        lastSync: Date? = nil,
        knownPaths: Set<String>? = nil
    ) -> SyncStatus {
        DriftResolver.resolve(
            remote: side(remote), local: side(local), lastSync: lastSync, knownPaths: knownPaths
        )
    }

    // MARK: - Erkennung

    @Test("Ein Pfad unter .git gehoert zum Repo darueber")
    func branchOfPath() {
        #expect(GitRepositories.branch(of: "Projekt/.git/HEAD") == "Projekt/.git/")
        #expect(GitRepositories.branch(of: "Projekt/.git/") == "Projekt/.git/")
        #expect(GitRepositories.branch(of: "Projekt/.git/refs/heads/main") == "Projekt/.git/")
    }

    @Test("Ein Repo im Stammordner selbst hat den leeren Stamm")
    func repositoryAtRoot() {
        #expect(GitRepositories.branch(of: ".git/HEAD") == ".git/")
        #expect(GitRepositories.root(of: ".git/", bare: []) == "")
        let status = resolve(remote: [entry(".git/refs/heads/main")])
        #expect(status.gitUnits.map(\.root) == [""])
        #expect(status.gitUnits.first?.displayName == "Stammordner")
    }

    @Test(".gitignore und .github duerfen nicht anschlagen")
    func prefixTrap() {
        #expect(GitRepositories.branch(of: "Projekt/.gitignore") == nil)
        #expect(GitRepositories.branch(of: "Projekt/.github/workflows/ci.yml") == nil)
        #expect(GitRepositories.branch(of: "Projekt/.gitmodules") == nil)
        let status = resolve(remote: [entry("Projekt/.github/workflows/ci.yml")])
        #expect(status.gitUnits.isEmpty)
        #expect(status.incoming.count == 1)
    }

    @Test("Verschachtelte Repos ergeben zwei Einheiten")
    func nestedRepositories() {
        let status = resolve(
            remote: [entry("a/.git/HEAD"), entry("a/b/.git/HEAD")]
        )
        #expect(status.gitUnits.map(\.root) == ["a/", "a/b/"])
        #expect(status.incoming.isEmpty)
    }

    @Test("Ein Submodul gehoert zum Zweig des Oberprojekts")
    func submoduleBelongsToSuperproject() {
        // Die Daten liegen unter <oberprojekt>/.git/modules/…, die .git-Datei
        // des Submoduls ist nur ein Verweis und bleibt ein normaler Eintrag.
        let status = resolve(
            remote: [
                entry("a/.git/modules/sub/HEAD"),
                entry("a/sub/.git"),
            ]
        )
        #expect(status.gitUnits.map(\.root) == ["a/"])
        #expect(status.incoming.map(\.path) == ["a/sub/.git"])
    }

    @Test("Ein blankes Repo wird an HEAD und objects erkannt")
    func bareRepository() {
        let paths = [
            entry("spiegel.git/", type: .directory),
            entry("spiegel.git/HEAD"),
            entry("spiegel.git/objects/", type: .directory),
            entry("spiegel.git/refs/heads/main"),
        ]
        let bare = GitRepositories.bareBranches(remote: side(paths), local: .empty)
        #expect(bare == ["spiegel.git/"])
        #expect(GitRepositories.root(of: "spiegel.git/", bare: bare) == "spiegel.git/")

        let status = resolve(remote: paths)
        #expect(status.gitUnits.map(\.branch) == ["spiegel.git/"])
        #expect(status.incoming.isEmpty)
    }

    @Test("Ein Ordner auf .git ohne HEAD bleibt ein gewoehnlicher Ordner")
    func directoryEndingInGitIsNotAlwaysBare() {
        let paths = [
            entry("notizen.git/", type: .directory),
            entry("notizen.git/liste.txt"),
        ]
        #expect(GitRepositories.bareBranches(remote: side(paths), local: .empty).isEmpty)
        #expect(resolve(remote: paths).gitUnits.isEmpty)
    }

    // MARK: - Faltung

    @Test("Nur die Gegenseite hat geschrieben: eingehend")
    func onlyRemoteWrote() {
        let status = resolve(
            remote: [
                entry("Projekt/.git/HEAD"),
                entry("Projekt/.git/refs/heads/main", offset: 600),
                entry("Projekt/quelle.swift", offset: 600),
            ],
            local: [
                entry("Projekt/.git/HEAD"),
                entry("Projekt/.git/refs/heads/main"),
                entry("Projekt/quelle.swift"),
            ]
        )
        #expect(status.gitUnits.count == 1)
        let unit = try! #require(status.gitUnits.first)
        #expect(unit.root == "Projekt/")
        #expect(unit.branch == "Projekt/.git/")
        #expect(unit.state == .incoming)
        #expect(unit.incomingCount == 1)
        #expect(unit.outgoingCount == 0)
        // Die Arbeitskopie bleibt Datei fuer Datei.
        #expect(status.incoming.map(\.path) == ["Projekt/quelle.swift"])
    }

    @Test("Nur dieser Rechner hat geschrieben: ausgehend")
    func onlyLocalWrote() {
        let status = resolve(
            remote: [entry("Projekt/.git/refs/heads/main")],
            local: [entry("Projekt/.git/refs/heads/main", offset: 600)]
        )
        #expect(status.gitUnits.map(\.state) == [.outgoing])
        #expect(status.outgoing.isEmpty)
    }

    @Test("Beide Seiten haben geschrieben: laeuft auseinander")
    func bothSidesWrote() {
        let status = resolve(
            remote: [
                entry("Projekt/.git/refs/heads/main", offset: 600),
                entry("Projekt/.git/logs/HEAD"),
            ],
            local: [
                entry("Projekt/.git/refs/heads/main"),
                entry("Projekt/.git/logs/HEAD", offset: 600),
            ]
        )
        #expect(status.gitUnits.map(\.state) == [.conflict])
        #expect(status.gitUnits.first?.bytes == 0)
    }

    @Test("Ein einzelner Konflikteintrag reicht fuer auseinander")
    func singleConflictIsEnough() {
        // Gleiche Zeit, andere Groesse: genau der Fall, den refs/heads/main
        // erzeugt, wenn beide Rechner denselben Zweig bewegt haben.
        let status = resolve(
            remote: [entry("Projekt/.git/refs/heads/main", size: 41)],
            local: [entry("Projekt/.git/refs/heads/main", size: 42)]
        )
        #expect(status.gitUnits.map(\.state) == [.conflict])
        #expect(status.conflicts.isEmpty)
        #expect(status.gitUnits.first?.conflictCount == 1)
    }

    @Test("Eine Loeschung drueben ist eine Schreibbewegung drueben")
    func deletionCountsAsWriting() {
        // Der Pfad lag beim letzten Abgleich auf beiden Seiten und fehlt jetzt
        // auf dem Server: dort wurde geraeumt, hier ist nichts passiert.
        let status = resolve(
            remote: [entry("Projekt/.git/HEAD")],
            local: [entry("Projekt/.git/HEAD"), entry("Projekt/.git/refs/heads/alt")],
            knownPaths: ["Projekt/.git/HEAD", "Projekt/.git/refs/heads/alt"]
        )
        let unit = try! #require(status.gitUnits.first)
        #expect(unit.state == .incoming)
        #expect(unit.incomingCount == 1)
        #expect(status.deletionsOnPull.isEmpty)
    }

    @Test("Ohne Bewegung unter .git entsteht keine Einheit")
    func noDriftNoUnit() {
        let status = resolve(
            remote: [entry("Projekt/.git/HEAD"), entry("Projekt/quelle.swift", offset: 600)],
            local: [entry("Projekt/.git/HEAD"), entry("Projekt/quelle.swift")]
        )
        #expect(status.gitUnits.isEmpty)
        #expect(status.incoming.map(\.path) == ["Projekt/quelle.swift"])
    }

    @Test(".git auf einer Seite Datei, auf der anderen Ordner")
    func gitFileVersusDirectory() {
        // Aus einem Submodul wurde ein eigenes Repo oder umgekehrt. Der Ordner
        // bildet eine Einheit, die Datei bleibt ein Einzeleintrag daneben.
        let status = resolve(
            remote: [entry("Projekt/.git/", type: .directory), entry("Projekt/.git/HEAD")],
            local: [entry("Projekt/.git")]
        )
        #expect(status.gitUnits.map(\.state) == [.incoming])
        #expect(status.outgoing.map(\.path) == ["Projekt/.git"])
    }

    @Test("Die Bytes der Einheit stecken in der Richtungssumme")
    func bytesFollowDirection() {
        let status = resolve(
            remote: [entry("Projekt/.git/objects/ab/cdef", size: 4096)],
            local: []
        )
        let unit = try! #require(status.gitUnits.first)
        #expect(unit.bytes == 4096)
        #expect(status.incomingBytes == 4096)
        #expect(status.outgoingBytes == 0)
    }

    @Test("Eine offene Einheit heisst: nicht auf gleichem Stand")
    func openUnitBreaksInSync() {
        let status = resolve(
            remote: [entry("Projekt/.git/refs/heads/main", offset: 600)],
            local: [entry("Projekt/.git/refs/heads/main")]
        )
        #expect(status.incoming.isEmpty)
        #expect(status.outgoing.isEmpty)
        #expect(status.conflicts.isEmpty)
        #expect(!status.isInSync)
    }
}
