import Foundation

/// Der Stand, den alle Rechner teilen, abgelegt auf der Gegenstelle.
///
/// Bis hierher lagen der letzte Abgleich und der gemeinsame Bestand nur lokal,
/// je Rechner, unter einer je Rechner eigenen Profilkennung. Im Alltag mit
/// mehreren Macs folgt daraus zweierlei, und beides ohne dass irgendwo ein
/// Fehler passiert waere:
///
/// Eine Datei, die A auf der Gegenstelle geloescht hat, ist fuer B "nur hier
/// vorhanden", also neu, und wandert beim naechsten Hochladen wieder hinueber.
/// Die Loeschung ist rueckgaengig gemacht, ohne dass jemand es merkt.
///
/// Umgekehrt: Eine Datei, die A neu hochgeladen hat, steht bei B je nach
/// Zeitstempel auf der Loeschliste, weil B sie noch nie gesehen hat und ihr
/// Zeitstempel aelter ist als Bs letzter Abgleich.
///
/// Beide Rechner tun dabei genau das, was ihre Buecher sagen. Der Fehler liegt
/// darin, dass jeder ein eigenes Buch fuehrt. Deshalb liegt das Buch jetzt
/// dort, wo es hingehoert: beim Ziel.
///
/// Was das nicht ist: ein Mehrschreiber-Sync. Zwei Rechner, die dieselbe Datei
/// aendern, erzeugen weiterhin einen Konflikt, der von Hand zu entscheiden ist.
/// Das ist ehrlicher als jede Automatik.
public struct SharedState: Codable, Sendable {
    public static let fileName = ".synctool/stand.json"
    public static let currentSchema = 2

    /// Wann zuletzt erfolgreich abgeglichen wurde, von welchem Rechner auch
    /// immer.
    public var lastSync: Date?
    /// Wer zuletzt geschrieben hat.
    public var lastMachine: String
    public var writtenAt: Date
    public var schema: Int?

    /// Kein gemeinsamer Bestand mehr.
    ///
    /// Hier stand die Liste aller Pfade, die beim letzten Lauf auf beiden
    /// Seiten lagen. Zwei Gruende, beide ausreichend:
    ///
    /// Sie hat nie etwas entschieden. `knownPaths` beantwortet die Frage, ob
    /// *dieser* Rechner den Pfad beim letzten Abgleich schon hatte, und dafuer
    /// ist der Bestand eines anderen die falsche Quelle. Das stand schon in
    /// `SyncEngine.check` und war der Grund, sie nur noch zu lesen.
    ///
    /// Und sie war teuer: Bei dreissigtausend Dateien sind das dreieinhalb
    /// Megabyte, die nach jedem Lauf ueber die Leitung gingen, durch eine Pipe
    /// an ein `cat` auf der Gegenseite. Genau daran stand die App still.
    ///
    /// Was bleibt, ist die Auskunft: wer zuletzt gelaufen ist und wann. Ein
    /// paar Dutzend Bytes, und genau die Frage, die man sich bei mehreren
    /// Rechnern stellt.
    public var isTrustworthy: Bool { schema == Self.currentSchema }

    public init(
        lastSync: Date?,
        lastMachine: String,
        writtenAt: Date = Date(),
        schema: Int? = currentSchema
    ) {
        self.lastSync = lastSync
        self.lastMachine = lastMachine
        self.writtenAt = writtenAt
        self.schema = schema
    }

    /// Name dieses Rechners, fuer `lastMachine`.
    ///
    /// Ueber `gethostname` und nicht ueber `Host.current().localizedName`:
    /// Letzteres fragt das Netz, kann Sekunden brauchen und im ungünstigen
    /// Fall haengen. Das hier liest einen Wert aus dem Kernel und ist fertig.
    /// Einmal berechnet, der Rechner benennt sich waehrend eines Laufs nicht um.
    public static let machineName: String = {
        var puffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&puffer, puffer.count - 1) == 0 else { return "unbekannt" }
        // `.local` weg: Das sagt niemandem etwas, und im Statusfenster steht
        // es sonst hinter jedem Rechnernamen.
        let name = String(cString: puffer)
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "unbekannt" : name
    }()

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// `nil` bei allem, was sich nicht lesen laesst.
    ///
    /// Ein beschaedigter oder fremder Stand darf keinen Lauf verhindern: Dann
    /// gilt eben der lokale, und das ist der Zustand von vorher.
    public static func decoded(_ data: Data) -> SharedState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SharedState.self, from: data),
            state.isTrustworthy
        else { return nil }
        return state
    }
}

/// Die Sperre gegen zwei Rechner, die gleichzeitig laufen.
///
/// Ohne sie koennen zwei Macs, die parallel mit Loeschen hochladen, sich
/// gegenseitig genau die Dateien wegraeumen, die der andere gerade geschrieben
/// hat, und beide schreiben danach einen Stand, der den eigenen als
/// gemeinsamen behauptet.
public struct SyncLock {
    public static let directory = ".synctool/lock"
    /// Danach gilt eine Sperre als liegengeblieben.
    ///
    /// Ein abgestuerzter Lauf kann seine Sperre nicht aufraeumen, und eine
    /// Sperre, die niemand mehr loest, legt das Profil fuer immer still. Eine
    /// Stunde ist lang genug fuer jeden ehrlichen Lauf und kurz genug, dass
    /// niemand auf die Idee kommt, von Hand einzugreifen.
    public static let staleAfter: TimeInterval = 3600

    /// Was in der Sperre steht, damit ein Mensch sie einordnen kann.
    public static func note(at date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        return "\(SharedState.machineName)\n\(formatter.string(from: date))\n"
    }

    /// Ist diese Sperre liegengeblieben?
    ///
    /// Reine Textarithmetik, damit sie sich ohne Gegenstelle pruefen laesst.
    /// Laesst sich der Zeitpunkt nicht lesen, gilt die Sperre als gueltig: Im
    /// Zweifel lieber warten als zwei Laeufe nebeneinander.
    public static func isStale(_ note: String, now: Date = Date()) -> Bool {
        let lines = note.split(separator: "\n").map(String.init)
        guard lines.count >= 2,
            let date = ISO8601DateFormatter().date(from: lines[1])
        else { return false }
        return now.timeIntervalSince(date) > staleAfter
    }
}
