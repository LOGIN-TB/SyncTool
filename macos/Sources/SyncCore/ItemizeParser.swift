import Foundation

public enum ChangeKind: String, Sendable {
    case created
    case updated
    /// Nur Zeitstempel oder Rechte weichen ab, der Inhalt sieht gleich aus.
    case metadataOnly
    case deleted
}

public enum ItemType: String, Sendable {
    case file
    case directory
    case symlink
    case device
    case special
}

public struct ChangeItem: Sendable, Hashable, Identifiable {
    public var id: String { "\(path)#\(kind.rawValue)" }
    public let path: String
    public let kind: ChangeKind
    public let type: ItemType
    public let size: Int64
    /// Aenderungszeit der Quelldatei dieses Laufs. Beide Trockenlaeufe laufen
    /// auf demselben Rechner, deshalb sind die Werte vergleichbar.
    public let modified: Date?
    /// Unveraenderte %i-Spalte, hilft beim Nachvollziehen im Protokoll.
    public let flags: String

    public init(
        path: String,
        kind: ChangeKind,
        type: ItemType,
        size: Int64,
        modified: Date? = nil,
        flags: String
    ) {
        self.path = path
        self.kind = kind
        self.type = type
        self.size = size
        self.modified = modified
        self.flags = flags
    }
}

/// Uebersetzt `--itemize-changes --out-format=%i|%l|%M|%n` in typisierte Eintraege.
///
/// Deckt beide Varianten ab: rsync 3.x liefert elf Flag-Zeichen und schickt
/// auch Loeschzeilen durch das Ausgabeformat, openrsync liefert neun Zeichen
/// und schreibt `*deleting <pfad>` daran vorbei.
public enum ItemizeParser {
    public static let outFormat = "%i|%l|%M|%n"

    /// Ausgabeformat des Bestandslaufs.
    ///
    /// `%L` steht am Ende, nicht in der Mitte: Ein Pfad darf ein "|" enthalten,
    /// und nur so bleibt er eindeutig, weil alles zwischen den festen Feldern
    /// vorn und dem Symlink-Ziel hinten zum Pfad gehoert.
    public static let inventoryFormat = "%i|%l|%M|%n|%L"

    /// Dasselbe mit Pruefsumme. Nur fuer rsync 3.x: openrsync kennt `%C` nicht
    /// und schreibt das Literal in die Zeile.
    public static let inventoryChecksumFormat = "%i|%l|%M|%C|%n|%L"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd-HH:mm:ss"
        return formatter
    }()

    /// Ergebnis eines Durchlaufs samt der Zeilen, die bewusst draussen bleiben.
    public struct ParseResult: Sendable {
        public let items: [ChangeItem]
        /// Symlinks, an denen nur Rechte oder Zeiten abweichen. Kein Lauf in
        /// keiner Richtung bekommt das weg, also nur zaehlen.
        public let skippedLinkAttributes: Int

        public init(items: [ChangeItem], skippedLinkAttributes: Int) {
            self.items = items
            self.skippedLinkAttributes = skippedLinkAttributes
        }
    }

    public static func parse(_ output: String) -> [ChangeItem] {
        parseCounting(output).items
    }

    public static func parseCounting(_ output: String) -> ParseResult {
        var items: [ChangeItem] = []
        var skipped = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            switch classify(String(line)) {
            case .item(let item): items.append(item)
            case .linkAttributesOnly: skipped += 1
            case .nothing: continue
            }
        }
        return ParseResult(items: items, skippedLinkAttributes: skipped)
    }

    public static func parseLine(_ raw: String) -> ChangeItem? {
        if case .item(let item) = classify(raw) { return item }
        return nil
    }

    /// Zerlegt eine Zeile eines Bestandslaufs.
    ///
    /// `withChecksum` muss zu dem Format passen, mit dem der Lauf gestartet
    /// wurde, sonst rutschen die Felder um eins.
    public static func parseInventoryLine(
        _ raw: String, withChecksum: Bool
    ) -> InventoryEntry? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("*deleting") else { return nil }

        let fields = line.components(separatedBy: "|")
        let pathStart = withChecksum ? 4 : 3
        // Feste Felder vorn, das Symlink-Ziel hinten, dazwischen der Pfad.
        guard fields.count > pathStart else { return nil }

        let characters = Array(fields[0])
        guard characters.count >= 2 else { return nil }

        let path = fields[pathStart..<(fields.count - 1)].joined(separator: "|")
        guard !path.isEmpty else { return nil }

        let linkField = fields[fields.count - 1]
        let linkTarget = linkField.hasPrefix(" -> ") ? String(linkField.dropFirst(4)) : nil

        var checksum: String?
        if withChecksum {
            let value = fields[3].trimmingCharacters(in: .whitespaces)
            // Verzeichnisse und Symlinks bekommen von rsync nur Leerzeichen.
            checksum = value.isEmpty ? nil : value
        }

        return InventoryEntry(
            path: path,
            type: itemType(from: characters[1]),
            size: Int64(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0,
            modified: timestampFormatter.date(from: fields[2].trimmingCharacters(in: .whitespaces)),
            linkTarget: linkTarget,
            checksum: checksum
        )
    }

    /// Alle Bestandszeilen einer Ausgabe, ohne den Wurzeleintrag.
    public static func parseInventory(
        _ output: String, withChecksum: Bool, capturedAt: Date = Date()
    ) -> SideInventory {
        let entries = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseInventoryLine(String($0), withChecksum: withChecksum) }
        return InventoryBuilder.build(from: entries, capturedAt: capturedAt)
    }

    enum LineResult {
        case item(ChangeItem)
        /// Symlink, an dem rsync nur Attribute bemaengelt.
        case linkAttributesOnly
        case nothing
    }

    static func classify(_ raw: String) -> LineResult {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .nothing }

        if line.hasPrefix("*deleting") {
            guard let item = parseDeletion(line) else { return .nothing }
            return .item(item)
        }

        let fields = line.components(separatedBy: "|")
        guard fields.count >= 4 else { return .nothing }

        let flags = fields[0]
        let size = Int64(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let modified = timestampFormatter.date(from: fields[2].trimmingCharacters(in: .whitespaces))
        // Pfade duerfen selbst "|" enthalten, deshalb der Rest als Ganzes.
        let path = fields[3...].joined(separator: "|")
        guard !path.isEmpty else { return .nothing }

        let characters = Array(flags)
        guard characters.count >= 2 else { return .nothing }

        // "." an erster Stelle heisst: nichts zu tun, nur gemeldet.
        guard characters[0] != "." || hasAttributeChange(characters) else { return .nothing }

        let type = itemType(from: characters[1])

        // Bei Symlinks steht "." fuer "Ziel stimmt ueberein". Uebrig bleiben
        // Rechte und Zeiten, und die setzt keine Seite auf einem Symlink
        // zuverlaessig. rsync meldet das sonst nach jedem Lauf erneut.
        // Angelegte oder umgehaengte Symlinks bekommen "c" und bleiben drin.
        if characters[0] == "." && type == .symlink {
            return .linkAttributesOnly
        }

        return .item(
            ChangeItem(
                path: path,
                kind: kind(from: characters),
                type: type,
                size: size,
                modified: modified,
                flags: flags
            )
        )
    }

    private static func parseDeletion(_ line: String) -> ChangeItem? {
        let fields = line.components(separatedBy: "|")
        let path: String
        if fields.count >= 4 {
            // rsync 3.x schickt auch Loeschzeilen durch das Ausgabeformat.
            path = fields[3...].joined(separator: "|")
        } else {
            // openrsync: "*deleting pfad"
            path = String(line.dropFirst("*deleting".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard !path.isEmpty else { return nil }
        return ChangeItem(
            path: path,
            kind: .deleted,
            type: path.hasSuffix("/") ? .directory : .file,
            size: 0,
            modified: nil,
            flags: "*deleting"
        )
    }

    private static func hasAttributeChange(_ characters: [Character]) -> Bool {
        characters.dropFirst(2).contains { $0 != "." && $0 != " " }
    }

    private static func kind(from characters: [Character]) -> ChangeKind {
        let attributes = Array(characters.dropFirst(2))
        if attributes.contains("+") { return .created }

        // c = Pruefsumme abweichend, s = Groesse abweichend.
        let contentChanged = attributes.contains("c") || attributes.contains("s")
        return contentChanged ? .updated : .metadataOnly
    }

    private static func itemType(from character: Character) -> ItemType {
        switch character {
        case "f": return .file
        case "d": return .directory
        case "L": return .symlink
        case "D": return .device
        default: return .special
        }
    }
}
