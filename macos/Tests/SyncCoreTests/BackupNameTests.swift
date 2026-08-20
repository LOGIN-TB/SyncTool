import Foundation
import Testing

@testable import SyncCore

@Suite("Name der Archive")
struct BackupNameTests {
    /// 23.05.2026, 14:30 Uhr, in der Zeitzone des Testlaufs.
    private var date: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 23
        components.hour = 14
        components.minute = 30
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("Der Dateiname besteht aus Ordnername, bak und Datum")
    func nameIsFolderBakDate() {
        #expect(
            BackupName.fileName(root: "/Users/test/Develop", date: date)
                == "Develop-bak-2026-05-23.zip"
        )
    }

    /// Sortierbar heisst: alphabetisch ist gleich chronologisch.
    @Test("Das Datum steht als Jahr-Monat-Tag mit führenden Nullen")
    func dateIsSortable() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 3
        let januar = Calendar(identifier: .gregorian).date(from: components)!

        let früh = BackupName.fileName(root: "/x/Develop", date: januar)
        let spät = BackupName.fileName(root: "/x/Develop", date: date)
        #expect(früh == "Develop-bak-2026-01-03.zip")
        #expect(früh < spät)
    }

    @Test("Ein zweites Backup am selben Tag bekommt die Uhrzeit")
    func secondBackupGetsTheTime() {
        let belegt = ["Develop-bak-2026-05-23.zip"]
        let url = BackupName.nextFree(
            root: "/x/Develop", date: date, in: URL(fileURLWithPath: "/ziel"),
            exists: { belegt.contains($0.lastPathComponent) }
        )
        #expect(url?.lastPathComponent == "Develop-bak-2026-05-23-1430.zip")
    }

    @Test("Auch der Name mit Uhrzeit weicht aus, statt zu überschreiben")
    func thirdBackupGetsANumber() {
        let belegt = ["Develop-bak-2026-05-23.zip", "Develop-bak-2026-05-23-1430.zip"]
        let url = BackupName.nextFree(
            root: "/x/Develop", date: date, in: URL(fileURLWithPath: "/ziel"),
            exists: { belegt.contains($0.lastPathComponent) }
        )
        #expect(url?.lastPathComponent == "Develop-bak-2026-05-23-1430-02.zip")
    }

    /// zip ersetzt eine vorhandene Datei nicht, es schreibt sie fort. Eine
    /// liegengebliebene Teildatei wuerde sonst zur Mischung aus zwei Staenden.
    @Test("Die Suche überspringt auch liegengebliebene Teildateien")
    func partialFilesBlockTheName() {
        let belegt = ["Develop-bak-2026-05-23.zip.part"]
        let url = BackupName.nextFree(
            root: "/x/Develop", date: date, in: URL(fileURLWithPath: "/ziel"),
            exists: { belegt.contains($0.lastPathComponent) }
        )
        #expect(url?.lastPathComponent == "Develop-bak-2026-05-23-1430.zip")
    }

    @Test("Ist alles belegt, gibt es keinen Namen statt eines falschen")
    func exhaustedNamesReturnNil() {
        #expect(
            BackupName.nextFree(
                root: "/x/Develop", date: date, in: URL(fileURLWithPath: "/ziel"),
                exists: { _ in true }
            ) == nil
        )
    }

    @Test("Das Datum hängt nicht am Gebietsschema")
    func dateIgnoresTheLocale() {
        let vorher = BackupName.fileName(root: "/x/Develop", date: date)
        // Ein Kalender oder eine Sprache mit anderen Ziffern darf nichts ändern.
        #expect(vorher.contains("2026-05-23"))
        #expect(vorher.allSatisfy { $0.isASCII })
    }

    @Test("Schrägstriche und Doppelpunkte im Ordnernamen werden ersetzt")
    func awkwardFolderNamesAreCleaned() {
        #expect(BackupName.folderName(root: "/x/Mit:Doppelpunkt") == "Mit-Doppelpunkt")
        #expect(BackupName.folderName(root: "/x/Mit Leerzeichen") == "Mit Leerzeichen")
        #expect(BackupName.folderName(root: "/x/Ümläut") == "Ümläut")
    }

    @Test("Ein Stammordner ohne Namen fällt auf einen Ersatznamen zurück")
    func rootWithoutNameFallsBack() {
        #expect(BackupName.folderName(root: "/") == "Backup")
        #expect(BackupName.folderName(root: "") == "Backup")
    }

    @Test("Die Teildatei heißt wie das Archiv, nur mit part")
    func partialNameIsDerived() {
        let archiv = URL(fileURLWithPath: "/ziel/Develop-bak-2026-05-23.zip")
        #expect(BackupName.partial(for: archiv).lastPathComponent == "Develop-bak-2026-05-23.zip.part")
    }
}
