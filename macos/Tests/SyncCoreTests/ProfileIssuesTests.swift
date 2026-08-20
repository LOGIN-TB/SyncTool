import Foundation
import Testing

@testable import SyncCore

@Suite("Profil auf Vollständigkeit prüfen")
struct ProfileIssuesTests {
    private func complete() -> Profile {
        Profile(
            name: "Storage Box", localRoot: "/tmp", host: "box.example.org", port: 23,
            user: "u1", remotePath: "dev"
        )
    }

    @Test("Ein vollständiges Profil meldet keinen Mangel")
    func completeProfileHasNoIssues() {
        #expect(complete().issues().isEmpty)
        #expect(complete().isComplete)
    }

    @Test("Ein Profil ohne Serveradresse meldet genau einen Mangel am Feld host")
    func missingHostIsReportedOnItsField() {
        var profile = complete()
        profile.host = ""
        let issues = profile.issues()
        #expect(issues.count == 1)
        #expect(issues.first?.field == .host)
    }

    @Test("Jedes fehlende Feld meldet sich einzeln")
    func everyFieldReportsItself() {
        let empty = Profile(localRoot: "", host: "", user: "", remotePath: "", )
        let fields = Set(empty.issues().map(\.field))
        #expect(fields == [.localRoot, .host, .user, .remotePath])
    }

    @Test("Port 0 und Port 70000 gelten als Mangel, Port 22 und 23 nicht")
    func portRangeIsChecked() {
        for port in [0, 70_000, -1] {
            var profile = complete()
            profile.port = port
            #expect(profile.issues().contains { $0.field == .port }, "Port \(port)")
        }
        for port in [22, 23, 1, 65_535] {
            var profile = complete()
            profile.port = port
            #expect(!profile.issues().contains { $0.field == .port }, "Port \(port)")
        }
    }

    /// `issues()` laeuft je Zeile der Profilliste und je Tastendruck. Ein
    /// `fileExists` auf einem eingehaengten Netzlaufwerk hielte dabei die
    /// Oberflaeche an.
    @Test("Die Vollständigkeitsprüfung fasst das Dateisystem nicht an")
    func issuesNeverTouchTheFileSystem() {
        var profile = complete()
        profile.localRoot = "/gibt/es/ganz/sicher/nicht"
        // Der Ordner existiert nicht, gemeldet wird trotzdem nichts: `issues()`
        // prueft nur, ob überhaupt einer eingetragen ist.
        #expect(!profile.issues().contains { $0.field == .localRoot })
        // Die dateisystemgestützte Prüfung meldet ihn sehr wohl.
        #expect(profile.localRootIssue()?.field == .localRoot)
    }

    @Test("Ein leerer Stammordner wird von beiden Prüfungen gemeldet")
    func emptyRootIsReportedByBoth() {
        var profile = complete()
        profile.localRoot = ""
        #expect(profile.issues().contains { $0.field == .localRoot })
        #expect(profile.localRootIssue() != nil)
    }

    /// Der gemeldete Fehler: Der alte Filter verglich Zeichenketten und liess
    /// "Kein lokaler Ordner gewaehlt." stehen, weil der Praefix nicht passte.
    /// Ein frisches Profil konnte seine Verbindung damit nicht testen.
    @Test("Ein fehlender lokaler Ordner blockiert den Verbindungstest nicht")
    func missingLocalRootDoesNotBlockTheConnectionTest() {
        var profile = complete()
        profile.localRoot = ""
        let blocking = profile.issues().filter { $0.field != .localRoot }
        #expect(blocking.isEmpty)

        // Gegenprobe: Ein fehlender Server blockiert sehr wohl.
        profile.host = ""
        #expect(profile.issues().filter { $0.field != .localRoot }.count == 1)
    }

    @Test("Die alte Fehlerliste bleibt für vorhandene Aufrufer erhalten")
    func legacyListStillWorks() {
        var profile = complete()
        profile.host = ""
        profile.localRoot = ""
        let messages = profile.validationErrors()
        #expect(messages.contains("Kein Server angegeben."))
        #expect(messages.first == "Kein lokaler Ordner gewählt.")
    }

    // MARK: - Zusammenfassung

    @Test("Die Zusammenfassung nennt Benutzer, Server, Port und Ordner")
    func summaryNamesTheTarget() {
        #expect(complete().summary == "u1@box.example.org:23 · dev")
    }

    @Test("Ein leeres Profil sagt, dass es noch nicht eingerichtet ist")
    func emptySummarySaysSo() {
        #expect(Profile(host: "", user: "").summary == "Noch nicht eingerichtet")
    }
}
