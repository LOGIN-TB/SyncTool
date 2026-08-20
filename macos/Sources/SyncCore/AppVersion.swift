import Foundation

/// Fassung und Baunummer der laufenden App.
///
/// Quelle ist die Datei `VERSION` im Projektstamm. `Scripts/bundle.sh` traegt
/// beide Werte beim Bundeln in die Info.plist ein, hier werden sie von dort
/// gelesen. Damit gibt es genau eine Stelle zum Aendern, und der Finder zeigt
/// dieselben Zahlen wie das Programmfenster.
public enum AppVersion {
    /// "1.3.0", oder nil ausserhalb eines Bundles.
    public static var short: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// "2026.08.19-1", oder nil ausserhalb eines Bundles.
    public static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Fuer die Kopfzeile: "1.3.0 Build 2026.08.19-6".
    public static var display: String { display(short: short, build: build) }

    /// Langform fuer den Mauszeiger-Hinweis.
    public static var detailed: String { detailed(short: short, build: build) }

    /// Reine Funktionen, damit sich alle Faelle ohne Bundle pruefen lassen.
    ///
    /// Bei `swift run` gibt es keine Info.plist. Das ist kein Fehler, sondern
    /// die richtige Auskunft: Ein Lauf ohne Bundle ist kein verteilbarer Stand.
    public static func display(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else { return "Entwicklungsfassung" }
        guard let build, !build.isEmpty else { return short }
        return "\(short) Build \(build)"
    }

    public static func detailed(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else {
            return "Aus dem Quelltext gestartet, ohne Programmbündel. "
                + "Zum Vergleich mit anderen Rechnern „make app“ benutzen."
        }
        guard let build, !build.isEmpty else { return "Version \(short)" }
        return "Version \(short), Build \(build)"
    }
}
