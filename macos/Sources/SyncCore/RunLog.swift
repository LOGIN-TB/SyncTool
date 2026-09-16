import Foundation

/// Schreibt das Protokoll eines Laufs mit, damit ein Abbruch eine Spur hat.
///
/// Im Statusfenster steht das Protokoll nur, solange die App laeuft. Genau das
/// ist zu wenig, wenn sie waehrend eines Laufs verschwindet: Danach gibt es
/// keinen Absturzbericht, keine Zeile im Systemlog und nichts, woran sich
/// ablesen liesse, wie weit sie gekommen war.
///
/// Bewusst schlicht: anhaengen, mit Zeitstempel, und bei Ueberlaenge die
/// aeltere Haelfte wegwerfen. Keine Nebenlaeufigkeit, keine Rotation ueber
/// mehrere Dateien. Was hier stehen bleibt, soll im Fehlerfall lesbar sein und
/// sonst nicht auffallen.
public final class RunLog {
    /// Darueber wird gekuerzt. Ein Lauf ueber dreissigtausend Dateien schreibt
    /// viel, und eine Datei, die unbegrenzt waechst, ist selbst ein Problem.
    public static let maxBytes = 2_000_000

    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("protokoll.log")) {
        self.url = url
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public var path: String { url.path }

    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "\(formatter.string(from: Date()))  \(line)\n"
        guard let data = text.data(using: .utf8) else { return }

        _ = try? AppPaths.ensureSupportDirectory()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        trimIfNeeded()
    }

    /// Haelt die Datei in Grenzen, ohne den jungen Teil zu verlieren.
    private func trimIfNeeded() {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int, size > Self.maxBytes,
            let inhalt = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let zeilen = inhalt.split(separator: "\n", omittingEmptySubsequences: false)
        let behalten = zeilen.suffix(zeilen.count / 2).joined(separator: "\n")
        try? behalten.write(to: url, atomically: true, encoding: .utf8)
    }
}
