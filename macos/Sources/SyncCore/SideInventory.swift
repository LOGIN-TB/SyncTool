import Foundation

/// Ein Eintrag aus dem Bestandslauf einer Seite.
///
/// Anders als `ChangeItem` beschreibt das keine Aenderung, sondern was da ist.
/// Bewusst ohne die `%i`-Spalte: bei einer Vollauflistung steht dort fuer jeden
/// Eintrag dasselbe, und bei sechsstelligen Pfadzahlen zaehlt jedes Feld.
public struct InventoryEntry: Sendable, Hashable {
    /// Relativ zum Stammordner. Verzeichnisse enden auf "/", Symlinks nicht.
    public let path: String
    public let type: ItemType
    public let size: Int64
    public let modified: Date?
    /// Ziel eines Symlinks, ohne das " -> " aus der rsync-Ausgabe.
    public let linkTarget: String?
    /// Nur gesetzt, wenn der Lauf mit `--checksum` lief und rsync 3.x liefert.
    public let checksum: String?

    public init(
        path: String,
        type: ItemType,
        size: Int64,
        modified: Date?,
        linkTarget: String? = nil,
        checksum: String? = nil
    ) {
        self.path = path
        self.type = type
        self.size = size
        self.modified = modified
        self.linkTarget = linkTarget
        self.checksum = checksum
    }

    public var isDirectory: Bool { type == .directory }
}

/// Der vollstaendige Bestand einer Seite zu einem Zeitpunkt.
public struct SideInventory: Sendable {
    public let entries: [String: InventoryEntry]
    public let capturedAt: Date

    public init(entries: [String: InventoryEntry], capturedAt: Date = Date()) {
        self.entries = entries
        self.capturedAt = capturedAt
    }

    public var paths: Set<String> { Set(entries.keys) }
    public var fileCount: Int { entries.values.count { !$0.isDirectory } }
    public var directoryCount: Int { entries.values.count { $0.isDirectory } }
    public var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
    }

    /// Liegt unterhalb dieses Verzeichnisses noch etwas?
    ///
    /// Entscheidet, ob ein einseitiges Verzeichnis gemeldet wird. Ein Ordner
    /// voller Dateien braucht keinen eigenen Eintrag, seine Dateien ziehen ihn
    /// mit. Ein leerer Ordner dagegen ginge sonst nie ueber die Leitung.
    public func hasChildren(of directory: String) -> Bool {
        entries.keys.contains { $0 != directory && $0.hasPrefix(directory) }
    }

    public static let empty = SideInventory(entries: [:])
}

public enum InventoryBuilder {
    /// Baut den Bestand aus den Zeilen eines Bestandslaufs.
    ///
    /// Der Wurzeleintrag "./" faellt raus: rsync meldet ihn immer, er steht aber
    /// fuer den Stammordner selbst und nicht fuer etwas darin.
    public static func build(
        from entries: [InventoryEntry], capturedAt: Date = Date()
    ) -> SideInventory {
        var indexed: [String: InventoryEntry] = [:]
        indexed.reserveCapacity(entries.count)
        for entry in entries where entry.path != "./" && entry.path != "." {
            indexed[entry.path] = entry
        }
        return SideInventory(entries: indexed, capturedAt: capturedAt)
    }
}

/// Ein ausgeschlossener Zweig samt allem, was darunter liegt.
///
/// Einzeln aufgelistet waeren das schnell sechsstellig viele Pfade, und
/// "244.196 Einträge" beantwortet keine Frage. Der oberste ausgeschlossene
/// Pfad mit seiner Anzahl schon: daran sieht man, welche Regel greift.
public struct ExcludedBranch: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Eintraege in diesem Zweig, den Zweig selbst eingeschlossen.
    public let count: Int

    public init(path: String, count: Int) {
        self.path = path
        self.count = count
    }

    /// Fasst eine Pfadliste zu ihren obersten Zweigen zusammen.
    public static func group(_ paths: [String]) -> [ExcludedBranch] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var current: String?

        for path in paths.sorted() {
            if let root = current, path.hasPrefix(root) {
                counts[root, default: 0] += 1
                continue
            }
            // Nur Verzeichnisse koennen etwas unter sich haben.
            current = path.hasSuffix("/") ? path : nil
            counts[path] = 1
            order.append(path)
        }
        return order.map { ExcludedBranch(path: $0, count: counts[$0] ?? 1) }
            .sorted { ($0.count, $1.path) > ($1.count, $0.path) }
    }
}

/// Zahlen, die sich gegen einen FTP-Client halten lassen.
public struct InventoryReport: Sendable {
    public let remoteFiles: Int
    public let remoteDirectories: Int
    public let remoteBytes: Int64
    public let localFiles: Int
    public let localDirectories: Int
    public let localBytes: Int64
    /// Lokal vorhanden, aber wegen der Ausschlussliste nie betrachtet.
    public let excluded: [ExcludedBranch]

    public init(
        remoteFiles: Int = 0,
        remoteDirectories: Int = 0,
        remoteBytes: Int64 = 0,
        localFiles: Int = 0,
        localDirectories: Int = 0,
        localBytes: Int64 = 0,
        excluded: [ExcludedBranch] = []
    ) {
        self.remoteFiles = remoteFiles
        self.remoteDirectories = remoteDirectories
        self.remoteBytes = remoteBytes
        self.localFiles = localFiles
        self.localDirectories = localDirectories
        self.localBytes = localBytes
        self.excluded = excluded
    }

    public init(remote: SideInventory, local: SideInventory, excludedPaths: [String]) {
        self.init(
            remoteFiles: remote.fileCount,
            remoteDirectories: remote.directoryCount,
            remoteBytes: remote.totalBytes,
            localFiles: local.fileCount,
            localDirectories: local.directoryCount,
            localBytes: local.totalBytes,
            excluded: ExcludedBranch.group(excludedPaths)
        )
    }

    /// Alle ausgeschlossenen Eintraege, nicht nur die Zweige.
    public var excludedCount: Int { excluded.reduce(0) { $0 + $1.count } }
}
