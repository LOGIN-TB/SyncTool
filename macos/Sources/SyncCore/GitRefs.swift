import Foundation

/// Die Zeiger eines Repos: welcher Zweig auf welchem Commit steht.
///
/// Der Vergleich Datei fuer Datei taugt fuer ein `.git` nicht. git packt von
/// sich aus um, nach jedem `fetch` und nach genug Commits, und danach haben
/// beide Rechner dieselben Commits in verschieden benannten Packdateien. Datei
/// fuer Datei sieht das aus wie beidseitige Arbeit, obwohl sich nichts geaendert
/// hat. Verglichen wird deshalb, worauf es ankommt: die Refs.
public enum GitRefs {
    /// Alle Zeiger eines `.git`-Verzeichnisses, Refname auf Wert.
    ///
    /// `HEAD` steht als eigener Eintrag darin, bei einem Symref mit dem Ziel als
    /// Wert. Lose Refs stechen `packed-refs`, so wie git es auch haelt.
    public static func read(gitDirectory: String) -> [String: String] {
        var refs: [String: String] = [:]
        let base = URL(fileURLWithPath: gitDirectory, isDirectory: true)

        if let text = try? String(contentsOf: base.appendingPathComponent("packed-refs"), encoding: .utf8) {
            refs.merge(parsePackedRefs(text)) { _, new in new }
        }
        for (name, value) in looseRefs(in: base) { refs[name] = value }
        if let head = value(of: base.appendingPathComponent("HEAD")) { refs["HEAD"] = head }
        return refs
    }

    /// `packed-refs` zerlegen.
    ///
    /// Kommentarzeilen fallen raus, und die `^`-Zeilen ebenso: die nennen das
    /// Ziel eines annotierten Tags und haengen am Tag darueber.
    public static func parsePackedRefs(_ text: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            refs[name] = String(fields[0])
        }
        return refs
    }

    /// Stehen beide Seiten auf denselben Zeigern?
    ///
    /// Leer auf beiden Seiten zaehlt nicht als gleich: dann war entweder nichts
    /// zu lesen oder das Verzeichnis fehlt, und darauf laesst sich nichts
    /// gruenden.
    public static func settled(_ one: [String: String], _ other: [String: String]) -> Bool {
        !one.isEmpty && one == other
    }

    // MARK: - Intern

    private static func looseRefs(in base: URL) -> [(String, String)] {
        let refsDirectory = base.appendingPathComponent("refs", isDirectory: true)
        guard
            let walker = FileManager.default.enumerator(
                at: refsDirectory, includingPropertiesForKeys: [.isRegularFileKey]
            )
        else { return [] }

        let prefix = refsDirectory.standardizedFileURL.path + "/"
        var found: [(String, String)] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix), let value = value(of: url) else { continue }
            found.append(("refs/" + String(path.dropFirst(prefix.count)), value))
        }
        return found
    }

    /// Inhalt einer Ref-Datei. Ein Symref behaelt sein `ref:` davor, damit ein
    /// umgehaengter HEAD nicht mit einem Commit verwechselt wird.
    private static func value(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
