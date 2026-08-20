import Foundation

/// Kommandozeile und Dateiliste fuer den Packlauf.
public enum ZipArguments {
    public static let executable = "/usr/bin/zip"

    /// Stufe 1 statt der Vorgabe 6.
    ///
    /// Gemessen an 616 MB mit 54.909 Dateien: 13 s gegen 21 s, 192 MB gegen
    /// 176 MB. Also gut die doppelte Zeit fuer ein Zwanzigstel weniger Groesse.
    /// Ein Entwicklungsordner besteht ohnehin zu weiten Teilen aus bereits
    /// komprimierten Daten, an denen Deflate nichts holt.
    public static let compressionLevel = "-1"

    /// - `-y`: Symlinks bleiben Symlinks, statt ihr Ziel einzupacken.
    /// - `-@`: Dateinamen kommen von der Standardeingabe. Keine Bequemlichkeit,
    ///   sondern noetig: 265.811 Pfade sind rund 10 MB, `ARG_MAX` liegt bei 1 MB.
    ///
    /// Bewusst nicht dabei: `-X` (wirft die Unix-Zeitstempel weg), `-q` (die
    /// Ausgabezeilen sind der Fortschritt), `-r` (die Liste ist vollstaendig,
    /// Rekursion umginge die Ausschluesse), `-D` (leere Ordner sollen mit) und
    /// `-e` (die ZIP-2.0-Verschluesselung gilt seit Jahrzehnten als gebrochen).
    public static func arguments(archive: String) -> [String] {
        [compressionLevel, "-y", "-@", archive]
    }

    /// Was aus dem Bestand tatsaechlich ins Archiv kann.
    ///
    /// Sockets und Geraetedateien kann zip nicht, die braechten nur Status 18.
    /// Sortiert, damit zwei Laeufe ueber denselben Stand dasselbe Archiv ergeben.
    public static func fileList(from inventory: SideInventory) -> [String] {
        inventory.entries.values
            .filter { $0.type == .file || $0.type == .directory || $0.type == .symlink }
            .map(\.path)
            .sorted()
    }

    /// Eine Zeile je Pfad.
    ///
    /// Die Liste geht als Datei an den Prozess, nicht durch eine Pipe: Wer eine
    /// 10-MB-Liste hineinschreibt, waehrend zip auf stdout schreibt, verklemmt
    /// sich am vollen Puffer, und ein Abbruch mitten im Schreiben liefert
    /// SIGPIPE und beendet die App.
    @discardableResult
    public static func writeFileList(_ paths: [String], to url: URL) throws -> Int {
        try (paths.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return paths.count
    }
}

/// Liest die Ausgabe des Packlaufs.
public enum ZipOutputParser {
    public enum Line: Equatable {
        /// Ein Eintrag ist im Archiv gelandet.
        case added(String)
        /// Ein Name aus der Liste war nicht zu finden. Kein Abbruchgrund, aber
        /// es gehoert gemeldet, sonst fehlt still etwas im Archiv.
        case notMatched(String)
        case other
    }

    /// `  adding: unter/datei.txt (deflated 62%)`
    ///
    /// Der Pfad steht zwischen dem Doppelpunkt und der letzten oeffnenden
    /// Klammer, nicht der ersten: Klammern im Dateinamen bleiben so heil.
    public static func classify(_ raw: String) -> Line {
        let line = raw.trimmingCharacters(in: .whitespaces)

        for prefix in ["adding: ", "updating: "] where line.hasPrefix(prefix) {
            var rest = String(line.dropFirst(prefix.count))
            if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
                rest = String(rest[rest.startIndex..<open.lowerBound])
            }
            return rest.isEmpty ? .other : .added(rest)
        }

        // "zip warning: name not matched: pfad"
        if let range = line.range(of: "name not matched: ") {
            let name = String(line[range.upperBound...])
            return name.isEmpty ? .other : .notMatched(name)
        }
        return .other
    }
}
