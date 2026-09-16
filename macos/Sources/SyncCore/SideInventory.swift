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
    /// Lief der Bestandslauf sauber durch?
    ///
    /// `false` heisst: Waehrend der Auflistung sind Dateien verschwunden
    /// (rsync-Status 24). Die Liste ist dann unvollstaendig, und eine
    /// unvollstaendige Liste kann nur in eine Richtung falsch liegen: Ein
    /// fehlender Eintrag sieht aus wie ein geloeschter. Deshalb traegt der
    /// Bestand diese Auskunft mit, statt sie unterwegs zu verlieren.
    ///
    /// Vorbelegt mit `true`, damit jeder vorhandene Aufruf gueltig bleibt.
    public let isComplete: Bool

    public init(
        entries: [String: InventoryEntry],
        capturedAt: Date = Date(),
        isComplete: Bool = true
    ) {
        self.entries = entries
        self.capturedAt = capturedAt
        self.isComplete = isComplete
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
    ///
    /// Der Schluessel ist der rohe Pfad, so wie die Seite ihn meldet. Kein
    /// Normalisieren, und zwar mit Grund.
    ///
    /// Der Mac legt ueber den Finder NFD an, eine Datei, die auf der
    /// Linux-Seite entsteht, kommt in NFC. Das sind verschiedene Bytes, und in
    /// vielen Sprachen waeren es damit zwei Eintraege, einer "nur hier" und
    /// einer "nur drueben". Swift vergleicht Zeichenketten aber kanonisch
    /// aequivalent, und `Dictionary`, `Set` und `hasPrefix` tun es ebenso: Die
    /// beiden Schreibweisen sind hier von sich aus dieselbe Datei. Belegt in
    /// "Dieselbe Datei in NFC und NFD ist eine Datei".
    ///
    /// Zu normalisieren waere hier also wirkungslos und zugleich schaedlich:
    /// Der Pfad im Eintrag geht als Name an rsync, und ein umgeschriebener
    /// Name legte auf der Gegenseite eine zweite Datei an, statt die
    /// vorhandene zu treffen.
    public static func build(
        from entries: [InventoryEntry], capturedAt: Date = Date(), isComplete: Bool = true
    ) -> SideInventory {
        var indexed: [String: InventoryEntry] = [:]
        indexed.reserveCapacity(entries.count)
        for entry in entries where entry.path != "./" && entry.path != "." {
            indexed[entry.path] = entry
        }
        return SideInventory(entries: indexed, capturedAt: capturedAt, isComplete: isComplete)
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

/// Ein Repo auf gleichem Stand, mit seiner Eintragszahl je Seite.
///
/// Dieselben Commits, anders gepackt: `git` benennt seine Packdateien nach
/// ihrem Inhalt und packt nach jedem `fetch` und nach genug Commits von sich
/// aus um. Zwei Rechner auf demselben Stand haben deshalb verschieden viele
/// Dateien unter `.git/`, und genau das treibt die beiden Bestandszahlen im
/// Statusfenster auseinander, ohne dass etwas zu tun waere.
public struct SettledRepository: Sendable, Hashable, Identifiable {
    public var id: String { branch }
    /// Der `.git`-Zweig, etwa `Projekt/.git/`.
    public let branch: String
    public let remote: Int
    public let local: Int

    public init(branch: String, remote: Int, local: Int) {
        self.branch = branch
        self.remote = remote
        self.local = local
    }

    /// Mit Vorzeichen, nicht als Betrag: Nur so addieren sich die Zeilen zur
    /// Gesamtdifferenz, und genau das macht die Anzeige nachrechenbar.
    public var difference: Int { remote - local }

    /// `Projekt/.git/` wird zu `Projekt`.
    public var displayName: String {
        let root = branch.hasSuffix(".git/") ? String(branch.dropLast(5)) : branch
        return root.isEmpty ? "Stammordner" : String(root.dropLast())
    }
}

/// Ein Pfad, den es nur auf einer Seite gibt und der in keinem Repo auf
/// gleichem Stand liegt.
///
/// Das ist der Rest, der eine Differenz zwischen den beiden Bestandszahlen
/// wirklich erklaert oder eben offen laesst.
public struct OneSidedEntry: Sendable, Hashable, Identifiable {
    /// Bewusst hier genestet und nicht `RsyncArguments.InventorySide`: Das dort
    /// bezeichnet, welcher rsync-Lauf gemeint ist, das hier, auf welcher Seite
    /// ein Pfad liegt. Zwei verschiedene Fragen.
    public enum Side: String, Sendable {
        case remote
        case local
    }

    public var id: String { "\(side.rawValue):\(path)" }
    public let path: String
    public let side: Side

    public init(path: String, side: Side) {
        self.path = path
        self.side = side
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
    /// Die Repos auf gleichem Stand, je mit ihrer Eintragszahl auf beiden
    /// Seiten.
    ///
    /// Die Zahlen oben sind roh gezaehlt, damit sie sich gegen einen
    /// FTP-Client halten lassen. Ein Repo, dessen Zeiger beidseitig
    /// uebereinstimmen, wird trotzdem nicht uebertragen, und seine verschieden
    /// benannten Packdateien treiben die beiden Summen auseinander. Ohne diese
    /// Aufschluesselung stuende dort ein Unterschied ohne Erklaerung.
    public let settled: [SettledRepository]

    /// Pfade, die es nur auf einer Seite gibt und die in keinem Repo auf
    /// gleichem Stand liegen. Gekappt, `unexplainedCount` zaehlt vollstaendig.
    public let unexplained: [OneSidedEntry]
    public let unexplainedCount: Int

    /// Mehr als so viele einseitige Pfade braucht niemand in einer Liste. Wer
    /// dreihundert sieht, sieht dasselbe wie bei fuenfhundert.
    public static let unexplainedLimit = 500

    public init(
        remoteFiles: Int = 0,
        remoteDirectories: Int = 0,
        remoteBytes: Int64 = 0,
        localFiles: Int = 0,
        localDirectories: Int = 0,
        localBytes: Int64 = 0,
        excluded: [ExcludedBranch] = [],
        settled: [SettledRepository] = [],
        unexplained: [OneSidedEntry] = [],
        unexplainedCount: Int = 0
    ) {
        self.remoteFiles = remoteFiles
        self.remoteDirectories = remoteDirectories
        self.remoteBytes = remoteBytes
        self.localFiles = localFiles
        self.localDirectories = localDirectories
        self.localBytes = localBytes
        self.excluded = excluded
        self.settled = settled
        self.unexplained = unexplained
        self.unexplainedCount = unexplainedCount
    }

    public init(
        remote: SideInventory,
        local: SideInventory,
        excludedPaths: [String],
        settledBranches: Set<String> = []
    ) {
        let sorted = settledBranches.sorted()
        /// Der erste Zweig, unter dem dieser Pfad liegt.
        func branch(of path: String) -> String? {
            sorted.first { path.hasPrefix($0) }
        }

        var counts: [String: (remote: Int, local: Int)] = [:]
        for name in sorted { counts[name] = (0, 0) }
        var rest: [OneSidedEntry] = []

        for path in remote.paths {
            if let name = branch(of: path) { counts[name]?.remote += 1 }
            else if local.entries[path] == nil {
                rest.append(OneSidedEntry(path: path, side: .remote))
            }
        }
        for path in local.paths {
            if let name = branch(of: path) { counts[name]?.local += 1 }
            else if remote.entries[path] == nil {
                rest.append(OneSidedEntry(path: path, side: .local))
            }
        }
        rest.sort { ($0.path, $0.side.rawValue) < ($1.path, $1.side.rawValue) }

        self.init(
            remoteFiles: remote.fileCount,
            remoteDirectories: remote.directoryCount,
            remoteBytes: remote.totalBytes,
            localFiles: local.fileCount,
            localDirectories: local.directoryCount,
            localBytes: local.totalBytes,
            excluded: ExcludedBranch.group(excludedPaths),
            settled: sorted.map {
                SettledRepository(
                    branch: $0, remote: counts[$0]?.remote ?? 0, local: counts[$0]?.local ?? 0
                )
            },
            unexplained: Array(rest.prefix(Self.unexplainedLimit)),
            unexplainedCount: rest.count
        )
    }

    /// Alle ausgeschlossenen Eintraege, nicht nur die Zweige.
    public var excludedCount: Int { excluded.reduce(0) { $0 + $1.count } }

    /// Die Repos auf gleichem Stand, die tatsaechlich zur Differenz beitragen.
    ///
    /// Die meisten tun es nicht: Wer seit dem letzten Umpacken nichts getan
    /// hat, hat beidseitig dieselben Dateien. "Alle 22 Repos" zu nennen, wenn
    /// zwei davon gemeint sind, ist keine Erklaerung, sondern eine Zahl, die
    /// zu nichts passt, was darunter steht.
    public var settledContributors: [SettledRepository] {
        settled.filter { $0.difference != 0 }
    }

    public var settledRemote: Int { settled.reduce(0) { $0 + $1.remote } }
    public var settledLocal: Int { settled.reduce(0) { $0 + $1.local } }
    public var settledRepositories: Int { settled.count }

    /// Wie weit die beiden Summen auseinanderliegen.
    public var difference: Int {
        abs((remoteFiles + remoteDirectories) - (localFiles + localDirectories))
    }

    /// Bleibt ein Pfad uebrig, den die Repos auf gleichem Stand nicht erklaeren?
    ///
    /// Hier stand frueher ein Vergleich zweier Zahlen: Zieh die Repos ab, dann
    /// muss auf beiden Seiten dieselbe Zahl uebrigbleiben. Das ist kein Beweis,
    /// sondern eine Wette. Liegt eine Datei nur auf dem Server und eine andere
    /// nur hier, heben sich die beiden Abweichungen in der Rechnung gegenseitig
    /// auf, und die Anzeige behauptete, die Differenz laege in den Repos.
    /// Zwei Dateien, die nirgends liegen, wo das behauptet wird.
    ///
    /// Deshalb jetzt ueber die Mengen: Die Summen koennen sich nur durch Pfade
    /// unterscheiden, die es auf genau einer Seite gibt. Pfade auf beiden
    /// Seiten kuerzen sich heraus, egal wie verschieden ihr Inhalt ist. Bleibt
    /// nach Abzug der Repos auf gleichem Stand nichts uebrig, und nur dann, ist
    /// die Differenz erklaert.
    ///
    /// Wer das hier je wieder auf einen Zahlenvergleich zurueckbaut, weil es
    /// einfacher aussieht, baut den Fehler mit zurueck.
    public var hasUnexplainedEntries: Bool { unexplainedCount > 0 }
}
