import Foundation
import Testing

@testable import SyncCore

@Suite("Der Ordner der weggesicherten Fassungen")
struct VersionFolderTests {
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: text)!
    }

    @Test("Ein Ordner je Lauf, das Datum steht im Namen")
    func pathCarriesTheDate() {
        #expect(VersionFolder.path(at: date("2026-09-16-1432")) == ".synctool-versionen/2026-09-16-1432")
    }

    @Test("Was älter ist als die Aufbewahrung, fällt weg")
    func expiredFoldersAreListed() {
        let jetzt = date("2026-09-16-1200")
        let namen = [
            "2026-09-15-1000",  // gestern
            "2026-08-01-0900",  // vor sechs Wochen
            "2026-09-16-1159",  // eben
        ]
        #expect(VersionFolder.expired(namen, keepDays: 30, now: jetzt) == ["2026-08-01-0900"])
    }

    /// Damit ein Lauf nie den Ordner wegraeumt, den er gerade anlegt.
    @Test("Der Ordner dieses Laufs bleibt immer stehen")
    func todaysFolderSurvives() {
        let jetzt = date("2026-09-16-1200")
        let eigener = String(VersionFolder.path(at: jetzt).split(separator: "/").last!)
        #expect(VersionFolder.expired([eigener], keepDays: 1, now: jetzt).isEmpty)
    }

    /// Ein fremder Ordner traegt kein Datum im Namen. Was diese App nicht
    /// geschrieben hat, raeumt sie auch nicht weg.
    @Test("Fremde Ordner bleiben unangetastet")
    func unknownNamesAreLeftAlone() {
        let jetzt = date("2026-09-16-1200")
        let namen = ["notizen", "2020-01-01", "", "2020-13-45-9999", "2020-01-01-1200"]
        #expect(VersionFolder.expired(namen, keepDays: 30, now: jetzt) == ["2020-01-01-1200"])
    }

    /// 0 Tage heisst: gar nicht sichern. Dann gibt es auch nichts wegzuraeumen,
    /// und ein vorhandener Ordner aus einer Zeit mit Sicherungen bleibt liegen,
    /// statt beim Umstellen der Einstellung stillschweigend zu verschwinden.
    @Test("Ohne Aufbewahrung wird nichts weggeräumt")
    func zeroKeepDaysSweepsNothing() {
        #expect(VersionFolder.expired(["2020-01-01-1200"], keepDays: 0).isEmpty)
    }
}
