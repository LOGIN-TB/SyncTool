import Foundation

/// Der Ordner, in den ein Lauf legt, was er ersetzt oder loescht.
///
/// rsync kennt dafuer `-b --backup-dir=`. Relativ angegeben liegt der Ordner
/// immer auf der Empfaengerseite, in beiden Richtungen und bei beiden
/// rsync-Fassungen. Damit ist jedes Ueberschreiben und jede Loeschung
/// rueckholbar, und das ist die eine Aenderung, die aus einem Bedienfehler
/// einen Aerger statt eines Verlusts macht.
///
/// Kein `--suffix`: mit `--backup-dir` ist der Vorgabewert leer, der
/// urspruengliche Dateiname bleibt also erhalten. Wer etwas zurueckholen will,
/// findet es unter demselben Pfad wie vorher, nur eine Ebene tiefer.
public enum VersionFolder {
    /// Oberster Ordner. Steht so auch in `Profile.internalExcludes`: Was die
    /// App selbst im Ziel ablegt, gehoert nie in den Abgleich, und
    /// ausgeschlossen heisst bei rsync zugleich vor `--delete` geschuetzt.
    public static let root = ".synctool-versionen"

    /// `.synctool-versionen/2026-09-16-1432`.
    ///
    /// Ein Ordner je Lauf, damit sich die Fassungen eines Tages nicht
    /// gegenseitig ueberschreiben und das Alter am Namen ablesbar bleibt.
    public static func path(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(root)/\(formatter.string(from: date))"
    }

    /// Ordner, die vor dem Stichtag angelegt wurden.
    ///
    /// Reine Namensarithmetik, damit sie sich ohne Dateisystem und ohne
    /// Gegenstelle pruefen laesst. Das Datum kommt aus dem Namen und nicht aus
    /// dem Dateisystem: ueber ssh gibt es kein `stat`, auf das hier Verlass
    /// waere, und ein Ordnername, den diese App geschrieben hat, traegt es
    /// ohnehin. Was nicht nach einem eigenen Ordner aussieht, bleibt liegen.
    public static func expired(
        _ names: [String], keepDays: Int, now: Date = Date()
    ) -> [String] {
        guard keepDays > 0 else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return names.filter { name in
            guard let date = formatter.date(from: name) else { return false }
            return date < cutoff
        }
    }
}
