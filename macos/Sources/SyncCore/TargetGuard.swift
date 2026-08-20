import Foundation

/// Gemessene Tatsachen ueber die beiden Seiten eines Laufs.
///
/// Alles, was `TargetGuard` braucht, und nichts, was es selbst holen muss.
/// So laesst sich jede Regel ohne Dateisystem und ohne Netz pruefen.
public struct TargetFacts: Sendable, Equatable {
    /// Richtung des geplanten Laufs. Entscheidet, welche Seite die Quelle ist.
    public var direction: SyncDirection

    /// Wie viele Eintraege der Bestandslauf auf der Quellseite gefunden hat.
    public var sourcePathCount: Int

    /// Wie viele auf der Empfaengerseite liegen. Nur fuer die Meldung.
    public var destinationPathCount: Int

    /// Was beim letzten Abgleich auf beiden Seiten gemeinsam vorlag.
    public var rememberedPathCount: Int

    /// Kennung, die im Ziel liegen muss. Leer heisst: dieses Ziel fuehrt keine.
    public var expectedMarker: String

    /// Lag die Kennung im Ziel? `nil` heisst: nicht nachgesehen.
    public var markerFound: Bool?

    public init(
        direction: SyncDirection,
        sourcePathCount: Int,
        destinationPathCount: Int,
        rememberedPathCount: Int,
        expectedMarker: String = "",
        markerFound: Bool? = nil
    ) {
        self.direction = direction
        self.sourcePathCount = sourcePathCount
        self.destinationPathCount = destinationPathCount
        self.rememberedPathCount = rememberedPathCount
        self.expectedMarker = expectedMarker
        self.markerFound = markerFound
    }
}

/// Warum ein Lauf nicht laufen darf.
public enum TargetGuardError: LocalizedError, Equatable {
    /// Die Quellseite ist leer, obwohl dort beim letzten Abgleich etwas lag.
    case unexpectedlyEmpty(direction: SyncDirection, remembered: Int)
    /// Die Kennung fehlt: das ist nicht der Ordner von letztem Mal.
    case markerMissing(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedlyEmpty(let direction, let remembered):
            let source = direction == .push ? "Auf diesem Rechner" : "Auf dem Server"
            return
                "\(source) ist nichts zu finden, beim letzten Abgleich lagen dort "
                + "\(remembered) Einträge. Mit Löschen würde dieser Lauf die andere Seite "
                + "ausräumen, deshalb ist er abgebrochen. Meistens ist ein Laufwerk nicht "
                + "verbunden oder der Ordner wurde verschoben. Ohne Löschen läuft der "
                + "Abgleich weiterhin."
        case .markerMissing(let marker):
            return
                "Die Kennung \(marker) liegt nicht im Ziel. Das ist nicht der Ordner, der "
                + "beim letzten „Verbindung testen“ geprüft wurde. Abgebrochen, weil sonst "
                + "in den falschen Ordner geschrieben würde."
        }
    }
}

/// Die einzige Stelle, an der entschieden wird, ob ein Lauf laufen darf.
///
/// Der Grund: wenn eine Quelle unbemerkt leer ist, sieht rsync eine Seite ohne
/// Dateien, und `--delete` raeumt die andere aus. Das trifft nicht nur
/// Netzlaufwerke. Ein Stammordner auf einer externen Platte, die gerade nicht
/// angesteckt ist, ist derselbe Fall.
public enum TargetGuard {
    /// Ab so vielen erinnerten Pfaden ist eine voellig leere Quelle kein
    /// legitimer Erstlauf mehr, sondern ein nicht verbundenes Ziel.
    ///
    /// Bewusst niedrig: wer 25 Dateien abgleicht, verliert sie genauso wie
    /// jemand mit 25.000.
    public static let emptyTargetThreshold = 25

    /// `nil` heisst: los.
    ///
    /// Rein, damit sich jede Regel ohne Dateisystem pruefen laesst.
    public static func decide(_ facts: TargetFacts, needsDelete: Bool) -> TargetGuardError? {
        // Die Kennung gilt unabhaengig vom Loeschen: in den falschen Ordner
        // schreiben ist auch ohne `--delete` falsch.
        if !facts.expectedMarker.isEmpty, facts.markerFound == false {
            return .markerMissing(facts.expectedMarker)
        }
        // Ohne `--delete` kann nichts verschwinden, also gibt es nichts zu
        // verhindern. Ein leerer Ordner ist dann einfach ein leerer Ordner.
        guard needsDelete else { return nil }
        if facts.sourcePathCount == 0, facts.rememberedPathCount >= emptyTargetThreshold {
            return .unexpectedlyEmpty(
                direction: facts.direction, remembered: facts.rememberedPathCount
            )
        }
        return nil
    }
}
