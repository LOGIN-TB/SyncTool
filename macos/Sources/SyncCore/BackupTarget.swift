import Foundation

public enum BackupTargetError: LocalizedError {
    case noDestination
    case destinationMissing(String)
    case destinationInsideSource(String)
    case notEnoughSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .noDestination:
            return "Kein Zielordner für Backups gewählt. In den Einstellungen eintragen."
        case .destinationMissing(let path):
            return "Der Zielordner \(path) existiert nicht."
        case .destinationInsideSource(let path):
            return "Der Zielordner \(path) liegt im Stammordner. Das Backup von morgen "
                + "würde das Archiv von heute mit einpacken. Bitte einen Ordner außerhalb wählen."
        case .notEnoughSpace(let needed, let available):
            return "Zu wenig Platz: \(needed / 1_048_576) MB an Daten, \(available / 1_048_576) MB frei."
        }
    }
}

public enum BackupTarget {
    /// Liegt das Ziel im Quellbaum?
    ///
    /// Ein Vergleich der Pfadzeichenketten reicht nicht: APFS unterscheidet
    /// standardmaessig keine Gross- und Kleinschreibung, der Finder legt Namen
    /// in NFD an und das Terminal in NFC, und ein Symlink irgendwo im Pfad
    /// verdeckt die Verwandtschaft ganz. Verglichen wird deshalb die
    /// Dateiidentitaet, Ebene fuer Ebene nach oben.
    public static func isInside(_ destination: URL, of source: URL) -> Bool {
        let sourceURL = source.resolvingSymlinksInPath().standardizedFileURL
        guard let sourceID = identity(of: sourceURL) else { return false }

        var current = destination.resolvingSymlinksInPath().standardizedFileURL
        // Ein noch nicht angelegter Zielordner hat keine Identitaet. Dann beim
        // ersten vorhandenen Vorfahren anfangen.
        while true {
            if let id = identity(of: current), id == sourceID { return true }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
    }

    private struct Identity: Equatable {
        let file: NSObject
        let volume: NSObject
    }

    private static func identity(of url: URL) -> Identity? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]
            ),
            let file = values.fileResourceIdentifier as? NSObject,
            let volume = values.volumeIdentifier as? NSObject
        else { return nil }
        return Identity(file: file, volume: volume)
    }

    /// Freier Platz am Ziel. `ImportantUsage` zaehlt loeschbaren Cache mit und
    /// ist damit naeher an dem, was wirklich zur Verfuegung steht.
    public static func availableBytes(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Prueft alles, was vor dem Lauf feststehen muss.
    ///
    /// `requiredBytes` ist die unkomprimierte Groesse. Das Archiv wird deutlich
    /// kleiner, deshalb ist das eine grosszuegige Obergrenze und kein Beweis:
    /// `ignoreSpace` laesst den Nutzer trotzdem weitermachen.
    public static func validate(
        destination: String, source: String, requiredBytes: Int64, ignoreSpace: Bool = false
    ) throws {
        guard !destination.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BackupTargetError.noDestination
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw BackupTargetError.destinationMissing(destination) }

        let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
        if isInside(destinationURL, of: URL(fileURLWithPath: source, isDirectory: true)) {
            throw BackupTargetError.destinationInsideSource(destination)
        }

        guard !ignoreSpace, let available = availableBytes(at: destinationURL) else { return }
        if available < requiredBytes {
            throw BackupTargetError.notEnoughSpace(needed: requiredBytes, available: available)
        }
    }
}
