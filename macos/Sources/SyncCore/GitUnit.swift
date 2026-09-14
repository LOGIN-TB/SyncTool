import Foundation

/// Wohin ein Repo in diesem Lauf gehoert.
public enum GitUnitState: String, Sendable {
    /// Nur die Gegenseite hat seit dem letzten Abgleich in `.git` geschrieben.
    case incoming
    /// Nur dieser Rechner hat geschrieben.
    case outgoing
    /// Beide. Dann bleibt das Repo in diesem Lauf unberuehrt.
    case conflict
    /// Beide Seiten stehen auf denselben Zeigern. Die Dateien darunter weichen
    /// ab, weil git unabhaengig umgepackt hat, aber das Repo ist dasselbe.
    case settled

    public var label: String {
        switch self {
        case .incoming: return "vom Server holen"
        case .outgoing: return "zum Server schicken"
        case .conflict: return "läuft auseinander"
        case .settled: return "gleicher Stand"
        }
    }
}

/// Ein Git-Repo als ein einziger Eintrag statt als tausend Dateien.
///
/// Ein Repo ist keine Menge unabhaengiger Dateien. `refs/`, `logs/`,
/// `packed-refs`, `index` und `objects/` ergeben nur zusammen einen Stand.
/// Datei fuer Datei abgeglichen kommen die reinen Neuzugaenge an, waehrend
/// genau die Dateien stehenbleiben, die beide Rechner schreiben. Heraus kommt
/// ein `.git`, das git zu Recht als "N commits behind" meldet.
public struct GitUnit: Sendable, Hashable, Identifiable {
    public var id: String { root }
    /// Stamm des Repos, mit "/" am Ende. Leer heisst: der Stammordner selbst.
    public let root: String
    /// Der Zweig, um den es geht: `<root>.git/`, bei einem blanken Repo der
    /// Repo-Ordner selbst.
    public let branch: String
    public let state: GitUnitState
    /// Eintraege, die von der Gegenseite kommen, geloeschte eingeschlossen.
    public let incomingCount: Int
    /// Eintraege, die von hier ausgehen, geloeschte eingeschlossen.
    public let outgoingCount: Int
    public let conflictCount: Int
    /// Uebertragungsgroesse in der Richtung dieser Einheit. Bei `.conflict` 0,
    /// dort wird nichts uebertragen.
    public let bytes: Int64

    public init(
        root: String,
        branch: String,
        state: GitUnitState,
        incomingCount: Int,
        outgoingCount: Int,
        conflictCount: Int,
        bytes: Int64
    ) {
        self.root = root
        self.branch = branch
        self.state = state
        self.incomingCount = incomingCount
        self.outgoingCount = outgoingCount
        self.conflictCount = conflictCount
        self.bytes = bytes
    }

    /// Zusammengefasste Eintraege in der Richtung dieser Einheit.
    public var itemCount: Int {
        switch state {
        case .incoming: return incomingCount
        case .outgoing: return outgoingCount
        case .conflict, .settled: return incomingCount + outgoingCount + conflictCount
        }
    }

    /// Bricht einen Gleichstand auf, wenn diese Seite nachweislich dem
    /// fuehrenden System entspricht.
    ///
    /// Laufen die beiden Seiten des Sync-Ziels auseinander, kann der Vergleich
    /// allein nicht entscheiden. Steht das Repo hier aber auf dem Stand seiner
    /// Gegenstelle, ist die Frage beantwortet: was hier liegt, liegt auch dort,
    /// und was nur auf dem Sync-Ziel lag, liegt weiterhin auf dem Rechner, der
    /// es hochgeladen hat.
    public func resolved(with result: GitRepoResult?) -> GitUnit {
        guard state == .conflict, result?.matchesRemote == true else { return self }
        return GitUnit(
            root: root,
            branch: branch,
            state: .outgoing,
            incomingCount: incomingCount,
            outgoingCount: outgoingCount,
            conflictCount: conflictCount,
            bytes: bytes
        )
    }

    /// Fuer die Anzeige: ein leerer Stamm ist der Stammordner selbst.
    public var displayName: String { root.isEmpty ? "Stammordner" : String(root.dropLast()) }
}

/// Erkennt Repos allein aus den Pfaden beider Bestandslisten und faltet die
/// Einzelentscheidungen darunter zu einer je Repo zusammen.
///
/// Bewusst ohne Dateisystem und ohne Aufruf von `git`: dieselbe Mengenarithmetik
/// wie `DriftResolver`, damit sie sich ohne Sandkasten pruefen laesst.
public enum GitRepositories {
    /// Das Segment, an dem ein Zweig erkannt wird. Ueber das vollstaendige
    /// Segment, nicht ueber "enthaelt .git": `.github/` und `.gitignore` duerfen
    /// nicht anschlagen.
    private static let marker = "/.git/"
    private static let rootMarker = ".git/"

    /// Blanke Repos: ein Ordner, der auf `.git/` endet, aber nicht `.git` heisst,
    /// und der `HEAD` und `objects/` direkt unter sich hat.
    ///
    /// Ohne diese zweite Regel bliebe ein Klon mit `--bare` ein gewoehnlicher
    /// Ordner und liefe wieder Datei fuer Datei.
    public static func bareBranches(remote: SideInventory, local: SideInventory) -> Set<String> {
        bareBranches(in: remote.paths.union(local.paths))
    }

    public static func bareBranches(in paths: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for path in paths where path.hasSuffix(rootMarker) && !isDotGit(path) {
            guard paths.contains(path + "HEAD"), paths.contains(path + "objects/") else { continue }
            found.insert(path)
        }
        return found
    }

    /// Der Zweig, zu dem ein Pfad gehoert, oder `nil`.
    ///
    /// Das erste Vorkommen gewinnt. Bei einem Submodul liegen die Daten unter
    /// `<oberprojekt>/.git/modules/…` und gehoeren damit zum Oberprojekt, bei
    /// zwei verschachtelten Repos ueberlappen die Zweige nicht.
    public static func branch(of path: String, bare: Set<String> = []) -> String? {
        if path.hasPrefix(rootMarker) { return rootMarker }
        if let range = path.range(of: marker) {
            return String(path[path.startIndex..<range.upperBound])
        }
        // Der Schraegstrich am Ende trennt `foo.git/` sauber von `foo.github/`.
        return bare.first { path.hasPrefix($0) }
    }

    /// Alle Repo-Staemme in einer Pfadmenge, aufsteigend sortiert.
    ///
    /// Anders als `fold` braucht das keine Bewegung: auch ein Repo, das mit der
    /// Gegenseite auf gleichem Stand ist, kann gegenueber GitHub zurueckhaengen.
    public static func roots(in paths: Set<String>) -> [String] {
        let bare = bareBranches(in: paths)
        var found: Set<String> = []
        for path in paths {
            guard let branch = branch(of: path, bare: bare) else { continue }
            found.insert(root(of: branch, bare: bare))
        }
        return found.sorted()
    }

    /// Der Repo-Stamm zu einem Zweig.
    public static func root(of branch: String, bare: Set<String>) -> String {
        bare.contains(branch) ? branch : String(branch.dropLast(rootMarker.count))
    }

    private static func isDotGit(_ path: String) -> Bool {
        path == rootMarker || path.hasSuffix(marker)
    }

    /// Das Ergebnis der Faltung: die Einheiten und die fuenf Listen ohne die
    /// Pfade, die jetzt in einer Einheit stecken.
    public struct Folded: Sendable {
        public let units: [GitUnit]
        public let incoming: [DriftItem]
        public let outgoing: [DriftItem]
        public let conflicts: [ConflictItem]
        public let deletionsOnPull: [ChangeItem]
        public let deletionsOnPush: [ChangeItem]
    }

    private struct Tally {
        var incoming = 0
        var outgoing = 0
        var conflicts = 0
        var deletionsOnPull = 0
        var deletionsOnPush = 0
        var incomingBytes: Int64 = 0
        var outgoingBytes: Int64 = 0
    }

    public static func fold(
        incoming: [DriftItem],
        outgoing: [DriftItem],
        conflicts: [ConflictItem],
        deletionsOnPull: [ChangeItem],
        deletionsOnPush: [ChangeItem],
        bare: Set<String> = [],
        /// Zweige, deren Refs auf beiden Seiten uebereinstimmen.
        settled: Set<String> = []
    ) -> Folded {
        var tallies: [String: Tally] = [:]

        /// Nimmt aus einer Liste heraus, was in einem `.git`-Zweig liegt, und
        /// zaehlt es dort. Was uebrig bleibt, geht unveraendert weiter.
        func take<T>(_ items: [T], path: (T) -> String, count: (inout Tally, T) -> Void) -> [T] {
            var kept: [T] = []
            for item in items {
                guard let branch = branch(of: path(item), bare: bare) else {
                    kept.append(item)
                    continue
                }
                count(&tallies[branch, default: Tally()], item)
            }
            return kept
        }

        let keptIncoming = take(incoming, path: \.path) { tally, item in
            tally.incoming += 1
            tally.incomingBytes += item.size
        }
        let keptOutgoing = take(outgoing, path: \.path) { tally, item in
            tally.outgoing += 1
            tally.outgoingBytes += item.size
        }
        let keptConflicts = take(conflicts, path: \.path) { tally, _ in tally.conflicts += 1 }
        let keptPull = take(deletionsOnPull, path: \.path) { tally, _ in
            tally.deletionsOnPull += 1
        }
        let keptPush = take(deletionsOnPush, path: \.path) { tally, _ in
            tally.deletionsOnPush += 1
        }

        let units = tallies.map { branch, tally -> GitUnit in
            // Eine Loeschung auf der einen Seite ist eine Schreibbewegung auf der
            // anderen: `deletionsOnPull` heisst, die Gegenseite hat weggeraeumt.
            let remoteWrote = tally.incoming > 0 || tally.deletionsOnPull > 0
            let localWrote = tally.outgoing > 0 || tally.deletionsOnPush > 0
            let state: GitUnitState
            if settled.contains(branch) {
                // Dieselben Zeiger auf beiden Seiten. Was darunter abweicht,
                // sind Packdateien, und die neu zu uebertragen brächte nichts
                // ausser Last auf der Leitung.
                state = .settled
            } else if tally.conflicts > 0 || (remoteWrote && localWrote) {
                state = .conflict
            } else if remoteWrote {
                state = .incoming
            } else {
                state = .outgoing
            }
            return GitUnit(
                root: root(of: branch, bare: bare),
                branch: branch,
                state: state,
                incomingCount: tally.incoming + tally.deletionsOnPull,
                outgoingCount: tally.outgoing + tally.deletionsOnPush,
                conflictCount: tally.conflicts,
                bytes: state == .incoming
                    ? tally.incomingBytes : (state == .outgoing ? tally.outgoingBytes : 0)
            )
        }
        .sorted { $0.root < $1.root }

        return Folded(
            units: units,
            incoming: keptIncoming,
            outgoing: keptOutgoing,
            conflicts: keptConflicts,
            deletionsOnPull: keptPull,
            deletionsOnPush: keptPush
        )
    }
}
