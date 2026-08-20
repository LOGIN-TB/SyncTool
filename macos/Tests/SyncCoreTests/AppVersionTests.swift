import Foundation
import Testing

@testable import SyncCore

@Suite("Fassung und Baunummer")
struct AppVersionTests {
    /// Beides sichtbar, nicht nur im Mauszeiger-Hinweis: Die Zahlen sind dazu
    /// da, den Stand zweier Rechner nebeneinanderzuhalten.
    @Test("Die Kopfzeile zeigt Fassung und Baunummer")
    func headerShowsVersionAndBuild() {
        #expect(
            AppVersion.display(short: "1.3.0", build: "2026.08.19-1")
                == "1.3.0 Build 2026.08.19-1"
        )
    }

    @Test("Ohne Baunummer bleibt die Fassung allein stehen")
    func displayWithoutBuild() {
        #expect(AppVersion.display(short: "1.3.0", build: nil) == "1.3.0")
        #expect(AppVersion.display(short: "1.3.0", build: "") == "1.3.0")
    }

    /// Bei `swift run` gibt es keine Info.plist. Das ist kein Fehler, sondern
    /// die richtige Auskunft: ein Lauf ohne Buendel ist kein verteilbarer Stand.
    @Test("Ohne Bündel steht dort Entwicklungsfassung")
    func withoutABundleItSaysSo() {
        #expect(AppVersion.display(short: nil, build: nil) == "Entwicklungsfassung")
        #expect(AppVersion.display(short: "", build: nil) == "Entwicklungsfassung")
        #expect(AppVersion.detailed(short: nil, build: nil).contains("make app"))
    }

    @Test("Die Langform nennt Fassung und Baunummer")
    func detailedNamesBoth() {
        #expect(
            AppVersion.detailed(short: "1.3.0", build: "2026.08.19-2")
                == "Version 1.3.0, Build 2026.08.19-2"
        )
    }

    @Test("Ohne Baunummer bleibt die Fassung stehen")
    func detailedWithoutBuild() {
        #expect(AppVersion.detailed(short: "1.3.0", build: nil) == "Version 1.3.0")
        #expect(AppVersion.detailed(short: "1.3.0", build: "") == "Version 1.3.0")
    }
}

@Suite("Formatierung")
struct FormattingTests {
    /// Sechsstellige Bestaende sind ohne Trennung nicht zu erfassen.
    @Test("Große Zahlen bekommen eine Tausendertrennung")
    func largeNumbersAreGrouped() {
        let formatted = Format.number(265_910)
        #expect(formatted != "265910")
        #expect(formatted.filter(\.isNumber) == "265910")
    }

    @Test("Kleine Zahlen bleiben unverändert")
    func smallNumbersStayPlain() {
        #expect(Format.number(0) == "0")
        #expect(Format.number(42) == "42")
    }

    /// Sonst steht im selben Fenster "17.846 Dateien" neben "244202 Eintraege".
    @Test("Die Zählform benutzt dieselbe Trennung")
    func countUsesTheSameGrouping() {
        let counted = Format.count(265_910, singular: "Eintrag", plural: "Einträge")
        #expect(counted == "\(Format.number(265_910)) Einträge")
        #expect(Format.count(1, singular: "Eintrag", plural: "Einträge") == "1 Eintrag")
    }

    @Test("Ein gerade gesetzter Zeitpunkt heißt „gerade eben“, nicht „in 0 Sekunden“")
    func freshTimestampReadsNaturally() {
        #expect(Format.relative(Date()) == "gerade eben")
        #expect(Format.relative(nil) == "noch nie")
        #expect(Format.relative(Date().addingTimeInterval(-7200)).contains("Stunde"))
    }

    // MARK: - Pfadanzeige

    /// Die Tilde ist auf macOS die uebliche Schreibweise, und sie nennt den
    /// Benutzernamen nicht: ein Bildschirmfoto ist damit ohne Zutun anonym.
    @Test("Das Heimatverzeichnis wird zur Tilde")
    func homeBecomesTilde() {
        let home = NSHomeDirectory()
        #expect(Format.displayPath("\(home)/Develop") == "~/Develop")
        #expect(Format.displayPath(home) == "~")
    }

    @Test("Ein Pfad außerhalb des Heimatverzeichnisses bleibt unverändert")
    func pathsOutsideHomeStay() {
        #expect(Format.displayPath("/Volumes/Sicherung/Projekte") == "/Volumes/Sicherung/Projekte")
        #expect(Format.displayPath("") == "")
    }

    /// Gespeichert wird weiter der vollstaendige Pfad. Waere die Tilde mehr als
    /// eine Anzeige, liefe rsync gegen einen Pfad, den es nicht kennt.
    @Test("Die Tilde ist nur Anzeige und verändert das Profil nicht")
    func tildeIsDisplayOnly() {
        var profile = Profile(localRoot: "\(NSHomeDirectory())/Develop", transport: .localFolder)
        profile.remotePath = "\(NSHomeDirectory())/Ablage"
        #expect(profile.summary == "~/Ablage")
        #expect(profile.localRoot.hasPrefix("/"))
        #expect(profile.localSource.hasPrefix("/"))
    }
}
