import Foundation
import Testing

@testable import SyncCore

@Suite("Bestandszahlen")
struct InventoryReportTests {
    private func entry(_ path: String, size: Int64 = 100) -> InventoryEntry {
        InventoryEntry(
            path: path,
            type: path.hasSuffix("/") ? .directory : .file,
            size: size,
            modified: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    private func side(_ paths: [String]) -> SideInventory {
        InventoryBuilder.build(from: paths.map { entry($0) })
    }

    private func report(
        remote: [String], local: [String], settled: Set<String> = []
    ) -> InventoryReport {
        InventoryReport(
            remote: side(remote), local: side(local),
            excludedPaths: [], settledBranches: settled
        )
    }

    @Test("Gleiche Bestände lassen nichts offen")
    func equalSidesExplainThemselves() {
        let bericht = report(remote: ["a.txt", "unter/", "unter/b.txt"],
                             local: ["a.txt", "unter/", "unter/b.txt"])
        #expect(bericht.difference == 0)
        #expect(!bericht.hasUnexplainedEntries)
        #expect(bericht.unexplained.isEmpty)
    }

    /// Die Zusage, die die Anzeige nachrechenbar macht: Ist der Rest leer,
    /// addieren sich die Repo-Zeilen zur Gesamtdifferenz.
    @Test("Verschieden gepackte Repos erklären die Differenz vollständig")
    func settledRepositoriesAccountForTheWholeGap() {
        let bericht = report(
            remote: [
                "a.txt", "P/.git/", "P/.git/objects/", "P/.git/objects/pack-1",
                "P/.git/objects/pack-2", "P/.git/objects/pack-3",
            ],
            local: ["a.txt", "P/.git/", "P/.git/objects/", "P/.git/objects/pack-alles"],
            settled: ["P/.git/"]
        )
        #expect(!bericht.hasUnexplainedEntries)
        #expect(bericht.settledRepositories == 1)
        #expect(bericht.settled.first?.difference == 2)
        #expect(bericht.settled.reduce(0) { $0 + $1.difference } == bericht.difference)
        #expect(bericht.settled.first?.displayName == "P")
    }

    /// Der Fall, an dem die alte Pruefung vorbeilief.
    ///
    /// Sie verglich zwei Zahlen: Zieh die Repos ab, dann muss dieselbe Zahl
    /// uebrigbleiben. Hier bleibt sie das, und trotzdem liegen zwei Dateien
    /// nicht dort, wo die Anzeige es behauptete. Genau diese Wette darf nicht
    /// zurueckkommen.
    @Test("Zwei Abweichungen dürfen sich nicht gegenseitig wegkürzen")
    func oppositeGapsDoNotCancelOut() {
        let bericht = report(
            remote: ["nur-dort.txt", "P/.git/", "P/.git/p1", "P/.git/p2", "P/.git/p3"],
            local: ["nur-hier.txt", "P/.git/", "P/.git/alles"],
            settled: ["P/.git/"]
        )
        // Die alte Rechnung: remote 5 - 4 == local 3 - 2, also "erklärt".
        #expect(bericht.remoteFiles + bericht.remoteDirectories - bericht.settledRemote
            == bericht.localFiles + bericht.localDirectories - bericht.settledLocal)
        // Die neue Antwort.
        #expect(bericht.hasUnexplainedEntries)
        #expect(bericht.unexplained.map(\.path).sorted() == ["nur-dort.txt", "nur-hier.txt"])
        #expect(bericht.unexplained.first { $0.path == "nur-dort.txt" }?.side == .remote)
        #expect(bericht.unexplained.first { $0.path == "nur-hier.txt" }?.side == .local)
    }

    @Test("Ein einseitiger Pfad in einem Repo ohne Gleichstand bleibt offen")
    func oneSidedPathInAnUnsettledRepositoryCounts() {
        let bericht = report(
            remote: ["Q/.git/", "Q/.git/HEAD", "Q/.git/extra"],
            local: ["Q/.git/", "Q/.git/HEAD"],
            settled: []
        )
        #expect(bericht.hasUnexplainedEntries)
        #expect(bericht.unexplained.map(\.path) == ["Q/.git/extra"])
    }

    /// Der Beleg kommt aus den Mengen und nicht aus den gefalteten Listen.
    /// `DriftResolver` ueberspringt ein einseitiges Verzeichnis, das Kinder
    /// hat, mit `continue`; in den Summen zaehlt es trotzdem mit.
    @Test("Ein einseitiges Verzeichnis mit Kindern steht im Rest")
    func oneSidedDirectoryWithChildrenIsListed() {
        let bericht = report(remote: ["neu/", "neu/a.txt"], local: [])
        #expect(bericht.unexplained.map(\.path).sorted() == ["neu/", "neu/a.txt"])
    }

    @Test("Die Liste wird gekappt, die Zahl bleibt vollständig")
    func theListIsCappedButTheCountIsNot() {
        let viele = (0..<(InventoryReport.unexplainedLimit + 20)).map { "datei-\($0).txt" }
        let bericht = report(remote: viele, local: [])
        #expect(bericht.unexplainedCount == viele.count)
        #expect(bericht.unexplained.count == InventoryReport.unexplainedLimit)
    }

    /// Ein Pfad, den es auf beiden Seiten gibt, kann die Summen nicht
    /// auseinandertreiben, egal wie verschieden sein Inhalt ist.
    @Test("Gemeinsame Pfade kürzen sich heraus")
    func sharedPathsNeverShowUp() {
        let bericht = InventoryReport(
            remote: InventoryBuilder.build(from: [entry("a.txt", size: 100)]),
            local: InventoryBuilder.build(from: [entry("a.txt", size: 999)]),
            excludedPaths: []
        )
        #expect(!bericht.hasUnexplainedEntries)
        #expect(bericht.difference == 0)
    }
}
