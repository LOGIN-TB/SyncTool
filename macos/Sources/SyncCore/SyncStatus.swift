import Foundation

public enum DriftReason: String, Sendable {
    case onlyRemote
    case onlyLocal
    case remoteNewer
    case localNewer

    public var label: String {
        switch self {
        case .onlyRemote: return "nur auf dem Server"
        case .onlyLocal: return "nur lokal"
        case .remoteNewer: return "Server neuer"
        case .localNewer: return "lokal neuer"
        }
    }
}

public struct DriftItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let type: ItemType
    public let size: Int64
    public let reason: DriftReason
    public let remoteModified: Date?
    public let localModified: Date?

    public init(
        path: String,
        type: ItemType,
        size: Int64,
        reason: DriftReason,
        remoteModified: Date?,
        localModified: Date?
    ) {
        self.path = path
        self.type = type
        self.size = size
        self.reason = reason
        self.remoteModified = remoteModified
        self.localModified = localModified
    }
}

public enum ConflictReason: String, Sendable {
    /// Beide Seiten wurden nach dem letzten Abgleich geaendert.
    case bothChangedSinceLastSync
    /// Gleicher Zeitstempel, aber unterschiedlicher Inhalt.
    case sameTimeDifferentContent
    /// Zeitstempel liessen sich nicht vergleichen.
    case unknownTimestamps

    public var label: String {
        switch self {
        case .bothChangedSinceLastSync: return "beide Seiten seit dem letzten Abgleich geändert"
        case .sameTimeDifferentContent: return "gleiche Zeit, anderer Inhalt"
        case .unknownTimestamps: return "Zeitstempel unklar"
        }
    }
}

public struct ConflictItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let reason: ConflictReason
    public let remoteModified: Date?
    public let localModified: Date?
    public let remoteSize: Int64
    public let localSize: Int64

    public init(
        path: String,
        reason: ConflictReason,
        remoteModified: Date?,
        localModified: Date?,
        remoteSize: Int64,
        localSize: Int64
    ) {
        self.path = path
        self.reason = reason
        self.remoteModified = remoteModified
        self.localModified = localModified
        self.remoteSize = remoteSize
        self.localSize = localSize
    }
}

public struct SyncStatus: Sendable {
    public let checkedAt: Date
    public let lastSync: Date?
    /// Vom Server zu holen.
    public let incoming: [DriftItem]
    /// Zum Server zu schicken.
    public let outgoing: [DriftItem]
    /// Beim Herunterladen mit Löschen zu entfernende lokale Dateien. Nur was
    /// auf dem Server gelöscht wurde, nicht was hier neu entstanden ist.
    public let deletionsOnPull: [ChangeItem]
    /// Beim Hochladen mit Löschen zu entfernende Dateien auf dem Server. Nur
    /// was lokal gelöscht wurde, nicht was dort neu entstanden ist.
    public let deletionsOnPush: [ChangeItem]
    public let conflicts: [ConflictItem]
    /// Was beide Seiten tatsächlich enthalten. Die Zahlen lassen sich gegen
    /// einen FTP-Client halten, genau dafür sind sie da.
    public let report: InventoryReport
    /// Die gemessenen Bestände. Die Übertragung schreibt daraus die neue
    /// Bestandsliste fort, deshalb hängen sie am Ergebnis der Prüfung.
    public let remotePaths: Set<String>
    public let localPaths: Set<String>

    public var isInSync: Bool {
        incoming.isEmpty && outgoing.isEmpty && conflicts.isEmpty
            && deletionsOnPull.isEmpty && deletionsOnPush.isEmpty
    }

    public var incomingBytes: Int64 { incoming.reduce(0) { $0 + $1.size } }
    public var outgoingBytes: Int64 { outgoing.reduce(0) { $0 + $1.size } }

    /// Beim Hochladen mit Löschen vor dem Wegräumen zu schützen: neu auf dem Server.
    public var protectedOnPush: [String] {
        incoming.filter { $0.reason == .onlyRemote }.map(\.path)
    }
    /// Beim Herunterladen mit Löschen zu schützen: neu auf diesem Rechner.
    public var protectedOnPull: [String] {
        outgoing.filter { $0.reason == .onlyLocal }.map(\.path)
    }

    public init(
        checkedAt: Date,
        lastSync: Date?,
        incoming: [DriftItem],
        outgoing: [DriftItem],
        deletionsOnPull: [ChangeItem],
        deletionsOnPush: [ChangeItem],
        conflicts: [ConflictItem],
        report: InventoryReport = InventoryReport(),
        remotePaths: Set<String> = [],
        localPaths: Set<String> = []
    ) {
        self.checkedAt = checkedAt
        self.lastSync = lastSync
        self.incoming = incoming
        self.outgoing = outgoing
        self.deletionsOnPull = deletionsOnPull
        self.deletionsOnPush = deletionsOnPush
        self.conflicts = conflicts
        self.report = report
        self.remotePaths = remotePaths
        self.localPaths = localPaths
    }
}

/// Vergleicht die Bestaende beider Seiten und entscheidet je Pfad, wohin er gehoert.
///
/// Grundlage sind zwei vollstaendige Auflistungen, nicht rsyncs Differenzmeldung.
/// Damit steht fuer jeden Pfad fest, ob es ihn drueben gibt, statt es aus zwei
/// Halbinformationen zu erschliessen.
public enum DriftResolver {
    /// Kleinere Abstaende gelten als gleich. Deckungsgleich mit dem
    /// `--modify-window=1` der Uebertragungslaeufe, damit nicht die eine Seite
    /// "gleich" sagt, waehrend die andere noch uebertraegt.
    public static let tolerance: TimeInterval = 1

    public static func resolve(
        remote: SideInventory,
        local: SideInventory,
        lastSync: Date?,
        knownPaths: Set<String>? = nil,
        excludedPaths: [String] = [],
        checkedAt: Date = Date()
    ) -> SyncStatus {
        var incoming: [DriftItem] = []
        var outgoing: [DriftItem] = []
        var conflicts: [ConflictItem] = []
        var deletionsOnPull: [ChangeItem] = []
        var deletionsOnPush: [ChangeItem] = []

        for path in Set(remote.entries.keys).union(local.entries.keys).sorted() {
            switch (remote.entries[path], local.entries[path]) {
            case (let entry?, nil):
                // Ein Ordner voller Dateien braucht keinen eigenen Eintrag,
                // seine Dateien ziehen ihn mit. Ein leerer schon.
                if entry.isDirectory && remote.hasChildren(of: path) { continue }
                // Stand der Pfad beim letzten Abgleich schon da, wurde er hier
                // geloescht und gehoert nicht ins Herunterladen.
                if existedAtLastSync(entry, knownPaths: knownPaths, lastSync: lastSync) {
                    deletionsOnPush.append(deletion(entry))
                } else {
                    incoming.append(drift(entry, reason: .onlyRemote, remote: entry, local: nil))
                }
            case (nil, let entry?):
                if entry.isDirectory && local.hasChildren(of: path) { continue }
                if existedAtLastSync(entry, knownPaths: knownPaths, lastSync: lastSync) {
                    deletionsOnPull.append(deletion(entry))
                } else {
                    outgoing.append(drift(entry, reason: .onlyLocal, remote: nil, local: entry))
                }
            case (let remoteEntry?, let localEntry?):
                switch compare(remote: remoteEntry, local: localEntry, lastSync: lastSync) {
                case .same:
                    continue
                case .incoming:
                    incoming.append(
                        drift(
                            remoteEntry, reason: .remoteNewer,
                            remote: remoteEntry, local: localEntry
                        )
                    )
                case .outgoing:
                    outgoing.append(
                        drift(
                            localEntry, reason: .localNewer,
                            remote: remoteEntry, local: localEntry
                        )
                    )
                case .conflict(let reason):
                    conflicts.append(
                        ConflictItem(
                            path: path,
                            reason: reason,
                            remoteModified: remoteEntry.modified,
                            localModified: localEntry.modified,
                            remoteSize: remoteEntry.size,
                            localSize: localEntry.size
                        )
                    )
                }
            case (nil, nil):
                continue
            }
        }

        return SyncStatus(
            checkedAt: checkedAt,
            lastSync: lastSync,
            incoming: incoming,
            outgoing: outgoing,
            deletionsOnPull: deletionsOnPull,
            deletionsOnPush: deletionsOnPush,
            conflicts: conflicts,
            report: InventoryReport(
                remote: remote, local: local, excludedPaths: excludedPaths
            ),
            remotePaths: remote.paths,
            localPaths: local.paths
        )
    }

    private enum Decision {
        case same
        case incoming
        case outgoing
        case conflict(ConflictReason)
    }

    private static func compare(
        remote: InventoryEntry, local: InventoryEntry, lastSync: Date?
    ) -> Decision {
        // Verzeichnisse haben auf beiden Seiten nur den Namen gemeinsam. Die
        // Groesse ist die des Inode, die Zeit aendert sich bei jedem Schreiben
        // darin. Verglichen wird deshalb allein die Existenz.
        if remote.isDirectory || local.isDirectory {
            return remote.type == local.type ? .same : .conflict(.sameTimeDifferentContent)
        }

        // Symlinks: das Ziel entscheidet. Zeitstempel lassen sich auf einem
        // Symlink nicht zuverlaessig setzen, sie weichen dauerhaft ab.
        if remote.type == .symlink, local.type == .symlink,
            remote.linkTarget == local.linkTarget
        {
            return .same
        }

        // Zwei echte Pruefsummen sind das staerkste Argument und stechen jeden
        // Zeitvergleich. Ohne sie sagt gleiche Groesse nichts ueber den Inhalt.
        if let remoteSum = remote.checksum, let localSum = local.checksum,
            remote.type == local.type
        {
            if remoteSum == localSum { return .same }
        }

        guard let remoteTime = remote.modified, let localTime = local.modified else {
            return .conflict(.unknownTimestamps)
        }

        let difference = remoteTime.timeIntervalSince(localTime)
        if abs(difference) <= tolerance {
            // Genau rsyncs Schnelltest: gleiche Zeit und gleiche Groesse heisst
            // gleich. Lag eine Pruefsumme vor, ist der Fall oben schon erledigt.
            let sameContent =
                remote.type == local.type && remote.size == local.size
                && remote.checksum == nil && local.checksum == nil
            return sameContent ? .same : .conflict(.sameTimeDifferentContent)
        }

        // Beide Seiten nach dem letzten Abgleich angefasst: hier kann kein
        // Zeitstempelvergleich entscheiden, ohne moeglicherweise Arbeit zu verwerfen.
        if let lastSync, remoteTime > lastSync, localTime > lastSync {
            return .conflict(.bothChangedSinceLastSync)
        }
        return difference > 0 ? .incoming : .outgoing
    }

    /// War der Pfad beim letzten Abgleich auf beiden Seiten vorhanden?
    ///
    /// Mit Bestandsliste ist das eine Nachfrage, ohne sie eine Schaetzung:
    /// Was aelter ist als der letzte Abgleich, war damals schon da und wurde
    /// seitdem auf der anderen Seite geloescht. Die Schaetzung liegt daneben,
    /// wenn jemand Dateien mit altem Zeitstempel neu anlegt, etwa beim
    /// Zurueckspielen eines Backups. Sie gilt deshalb nur, solange fuer das
    /// Profil noch keine Bestandsliste geschrieben wurde.
    private static func existedAtLastSync(
        _ entry: InventoryEntry, knownPaths: Set<String>?, lastSync: Date?
    ) -> Bool {
        if let knownPaths { return knownPaths.contains(entry.path) }
        guard let lastSync, let modified = entry.modified else { return false }
        return modified < lastSync
    }

    private static func deletion(_ entry: InventoryEntry) -> ChangeItem {
        ChangeItem(
            path: entry.path,
            kind: .deleted,
            type: entry.type,
            size: entry.isDirectory ? 0 : entry.size,
            modified: entry.modified,
            flags: "*deleting"
        )
    }

    private static func drift(
        _ entry: InventoryEntry,
        reason: DriftReason,
        remote: InventoryEntry?,
        local: InventoryEntry?
    ) -> DriftItem {
        DriftItem(
            path: entry.path,
            type: entry.type,
            size: entry.isDirectory ? 0 : entry.size,
            reason: reason,
            remoteModified: remote?.modified,
            localModified: local?.modified
        )
    }
}
