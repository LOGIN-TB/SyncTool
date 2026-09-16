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

    /// Die Anzeige nannte frueher alle gleichstehenden Repos, auch die ohne
    /// Abweichung. Bei 22 Repos und zwei betroffenen stand dort "alle in 22
    /// Repos", waehrend die Liste darunter zwei Zeilen zeigte. Eine Zahl, die
    /// zu nichts passt, was daneben steht, ist schlimmer als keine.
    @Test("Genannt werden nur die Repos, die zur Differenz beitragen")
    func onlyContributingRepositoriesAreNamed() {
        let bericht = report(
            remote: [
                "P/.git/", "P/.git/pack-1", "P/.git/pack-2",
                "Q/.git/", "Q/.git/HEAD",
                "R/.git/", "R/.git/HEAD",
            ],
            local: [
                "P/.git/", "P/.git/alles",
                "Q/.git/", "Q/.git/HEAD",
                "R/.git/", "R/.git/HEAD",
            ],
            settled: ["P/.git/", "Q/.git/", "R/.git/"]
        )
        #expect(bericht.settledRepositories == 3)
        #expect(bericht.settledContributors.map(\.branch) == ["P/.git/"])
        #expect(bericht.settledContributors.reduce(0) { $0 + $1.difference } == bericht.difference)
        #expect(!bericht.hasUnexplainedEntries)
    }

    @Test("Gehen die Zahlen auf, trägt kein Repo bei")
    func nothingContributesWhenTheNumbersMatch() {
        let bericht = report(
            remote: ["P/.git/", "P/.git/HEAD"],
            local: ["P/.git/", "P/.git/HEAD"],
            settled: ["P/.git/"]
        )
        #expect(bericht.settledContributors.isEmpty)
        #expect(bericht.difference == 0)
    }

    // MARK: - Nach einem sauberen Abgleich stehen dieselben Zahlen da

    /// Die Forderung aus dem Betrieb, woertlich: Nach einem erfolgreichen Sync
    /// muessen die Zahlen links und rechts gleich sein.
    ///
    /// Roh gezaehlt sind sie das nicht, und daran ist auch nichts zu machen:
    /// Zwei Rechner auf demselben Stand haben verschieden viele Dateien unter
    /// `.git/`. Ein Repo auf gleichem Stand zaehlt deshalb nicht mit.
    @Test("Verschieden gepackte Repos zählen nicht mit, die Zahlen stimmen überein")
    func settledRepositoriesDoNotCount() {
        let bericht = report(
            remote: [
                "a.txt", "unter/", "unter/b.txt",
                "P/", "P/.git/", "P/.git/pack-1", "P/.git/pack-2", "P/.git/pack-3",
            ],
            local: [
                "a.txt", "unter/", "unter/b.txt",
                "P/", "P/.git/", "P/.git/alles",
            ],
            settled: ["P/.git/"]
        )
        // Roh gehen sie auseinander, und das bleibt auch sichtbar.
        #expect(bericht.remoteFiles != bericht.localFiles)
        // Was oben steht, stimmt überein.
        #expect(bericht.remoteFilesOutsideSettled == bericht.localFilesOutsideSettled)
        #expect(bericht.remoteDirectoriesOutsideSettled == bericht.localDirectoriesOutsideSettled)
        // Und zwar mit den richtigen Werten: a.txt und unter/b.txt sind Dateien,
        // unter/ und P/ sind Ordner. `P/.git/` selbst zählt zum Repo.
        #expect(bericht.remoteFilesOutsideSettled == 2)
        #expect(bericht.remoteDirectoriesOutsideSettled == 2)
    }

    /// Bleibt etwas ausserhalb der Repos offen, gehen die Zahlen weiterhin
    /// auseinander. Sie sollen die Wahrheit zeigen, nicht Ruhe.
    @Test("Ein offener Rest lässt die Zahlen auseinandergehen")
    func anUnexplainedRestKeepsTheNumbersApart() {
        let bericht = report(
            remote: ["a.txt", "nur-dort.txt", "P/.git/", "P/.git/pack-1"],
            local: ["a.txt", "P/.git/", "P/.git/alles"],
            settled: ["P/.git/"]
        )
        #expect(bericht.remoteFilesOutsideSettled != bericht.localFilesOutsideSettled)
        #expect(bericht.hasUnexplainedEntries)
        #expect(bericht.unexplained.map(\.path) == ["nur-dort.txt"])
    }

    @Test("Ohne Repos auf gleichem Stand ändert sich an den Zahlen nichts")
    func withoutSettledRepositoriesNothingChanges() {
        let bericht = report(remote: ["a.txt", "b.txt"], local: ["a.txt"])
        #expect(bericht.remoteFilesOutsideSettled == bericht.remoteFiles)
        #expect(bericht.localFilesOutsideSettled == bericht.localFiles)
    }
}
