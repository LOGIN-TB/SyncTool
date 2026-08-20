import Foundation

/// Bildet den Namen eines Archivs und sucht einen freien.
public enum BackupName {
    /// Erweiterung der fertigen Archive.
    public static let suffix = "zip"
    /// Solange geschrieben wird. Erst beim Umbenennen wird daraus ein Archiv,
    /// damit ein abgebrochener Lauf nicht wie ein fertiger aussieht.
    public static let partialSuffix = "zip.part"

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // Ohne feste Locale liefern manche Gebietsschemata andere Ziffern.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// Der Namensteil aus dem Stammordner.
    ///
    /// Ein "/" im Namen ist im Dateisystem unmoeglich, ein ":" zeigt der Finder
    /// als "/" an. Beides und alle Steuerzeichen werden ersetzt, damit aus einem
    /// ungewoehnlichen Ordnernamen kein unbrauchbarer Dateiname wird.
    public static func folderName(root: String) -> String {
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        // Erst den Rohwert pruefen: Ein leerer Pfad wuerde von URL relativ zum
        // Arbeitsverzeichnis aufgeloest, und "/" hat keine letzte Komponente.
        guard !trimmed.isEmpty, trimmed != "/" else { return fallbackName }

        let last = URL(fileURLWithPath: trimmed).standardizedFileURL.lastPathComponent
        let cleaned = last.map { character -> Character in
            if character == "/" || character == ":" { return "-" }
            return character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
                ? "-" : character
        }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "/" || name == "-" ? fallbackName : name
    }

    /// Wenn sich aus dem Stammordner kein brauchbarer Name ergibt.
    public static let fallbackName = "Backup"

    /// `Develop-bak-2026-05-23.zip`, mit Uhrzeit `…-2026-05-23-1430.zip`.
    public static func fileName(
        root: String, date: Date, withTime: Bool = false, index: Int? = nil
    ) -> String {
        var name = "\(folderName(root: root))-bak-\(formatter("yyyy-MM-dd").string(from: date))"
        if withTime { name += "-\(formatter("HHmm").string(from: date))" }
        if let index { name += String(format: "-%02d", index) }
        return "\(name).\(suffix)"
    }

    /// Der erste freie Name im Zielordner.
    ///
    /// Ueberschrieben wird nie: zip wuerde ein vorhandenes Archiv ohnehin nicht
    /// ersetzen, sondern einlesen und fortschreiben, und heraus kaeme eine
    /// Mischung aus zwei Staenden. Die Teildatei zaehlt deshalb mit.
    public static func nextFree(
        root: String, date: Date, in directory: URL, exists: (URL) -> Bool
    ) -> URL? {
        func candidate(_ name: String) -> URL? {
            let url = directory.appendingPathComponent(name)
            let partial = directory.appendingPathComponent(
                name.replacingOccurrences(of: ".\(suffix)", with: ".\(partialSuffix)")
            )
            return exists(url) || exists(partial) ? nil : url
        }

        if let url = candidate(fileName(root: root, date: date)) { return url }
        if let url = candidate(fileName(root: root, date: date, withTime: true)) { return url }
        // Zweimal in derselben Minute. Zweistellig, damit die Sortierung haelt.
        for index in 2...99 {
            if let url = candidate(fileName(root: root, date: date, withTime: true, index: index)) {
                return url
            }
        }
        return nil
    }

    /// Der Pfad, auf den waehrend des Laufs geschrieben wird.
    public static func partial(for archive: URL) -> URL {
        archive.deletingPathExtension().appendingPathExtension(partialSuffix)
    }
}
