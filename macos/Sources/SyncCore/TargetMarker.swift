import Foundation

/// Die Kennung, an der sich ein Zielordner wiedererkennen laesst.
///
/// Der gefaehrlichste Fall braucht keinen Fehler in der App: Der Zielordner
/// liegt auf einer Platte, die gerade nicht verbunden ist, und an ihrer Stelle
/// steht ein leerer Ordner mit demselben Pfad. `TargetGuard` faengt den Fall
/// "Quelle voellig leer" schon ab; ein Ziel, das nur nicht das richtige ist,
/// sah bisher genauso aus wie eines, in dem noch nichts liegt.
///
/// Die Kennung liegt deshalb im Ziel und wandert nicht mit: `.synctool-ziel`
/// steht in `Profile.systemExcludes`. Wuerde sie mitwandern, laege auf beiden
/// Seiten dieselbe, und sie koennte zwei Ordner nicht mehr auseinanderhalten.
public enum TargetMarker {
    public static let fileName = ".synctool-ziel"

    /// Eine neue Kennung. Nichts Geheimes, nur etwas, das sich nicht
    /// versehentlich wiederholt.
    public static func make() -> String { UUID().uuidString }

    /// Der Inhalt der Datei, mit abschliessendem Zeilenumbruch: So laesst sie
    /// sich auch mit `cat` lesen, ohne dass die Ausgabe klebt.
    public static func contents(_ id: String) -> String { id + "\n" }
}
