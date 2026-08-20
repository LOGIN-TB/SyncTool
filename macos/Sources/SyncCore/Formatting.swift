import Foundation

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    /// Zahlen mit Tausendertrennung.
    ///
    /// "265910" liest niemand auf einen Blick, "265.910" schon. Das Trennzeichen
    /// kommt aus dem Gebietsschema des Systems, damit es zum Rest der Oberflaeche passt.
    public static func number(_ value: Int) -> String {
        value.formatted(.number)
    }

    public static func timestamp(_ date: Date?) -> String {
        guard let date else { return "–" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func relative(_ date: Date?) -> String {
        guard let date else { return "noch nie" }
        // RelativeDateTimeFormatter macht aus einem gerade gesetzten Zeitpunkt
        // "in 0 Sekunden". Das liest sich wie eine Dauer und damit wie ein Lauf,
        // der gar nicht stattgefunden hat.
        let elapsed = Date().timeIntervalSince(date)
        if elapsed >= -1 && elapsed < 45 { return "gerade eben" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Pfad zum Anzeigen: das Heimatverzeichnis als Tilde.
    ///
    /// Gespeichert wird weiter der vollstaendige Pfad. Die Tilde ist auf macOS
    /// die uebliche Schreibweise, sie ist kuerzer, und sie nennt den
    /// Benutzernamen nicht: ein Bildschirmfoto der Oberflaeche ist damit ohne
    /// Zutun anonym.
    public static func displayPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// Zaehlt in einer Form, die im Deutschen auch bei eins stimmt.
    public static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(number(value)) \(value == 1 ? singular : plural)"
    }
}
