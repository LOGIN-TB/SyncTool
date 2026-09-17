import CoreGraphics
import Foundation

/// Wohin ein Menueleisten-Fenster gehoert, wenn sein Inhalt die Hoehe aendert.
///
/// Reine Rechnung, damit sie sich pruefen laesst. Die Mechanik drumherum, also
/// welche Benachrichtigung wann kommt, steckt in `MenuBarWindowAnchor` und ist
/// von aussen nicht zu erreichen; genau dort sind schon zwei Anlaeufe
/// gescheitert. Was sich rechnen laesst, soll deshalb nicht dort liegen.
public enum MenuBarGeometry {
    /// Abstand zur Menueleiste, wenn nichts gemessen wurde.
    ///
    /// Eine Schaetzung und als solche gekennzeichnet. Sie greift nur, solange
    /// keine verlaessliche Oberkante vorliegt, und liegt dann um ein paar Punkte
    /// daneben statt um mehrere hundert. Das ist der ganze Zweck: Ohne
    /// Ersatzwert bliebe das Fenster unkorrigiert, und unkorrigiert wandert es
    /// bei jedem Aufklappen ueber den halben Bildschirm.
    public static let assumedGap: CGFloat = 6

    /// Die Oberkante, an der das Fenster haengen soll.
    ///
    /// `measured` ist die Kante, die das System selbst gesetzt hat. Die ist
    /// richtig, sie stammt vom Statusitem. Fehlt sie, haengt ein
    /// Menueleisten-Fenster trotzdem immer unmittelbar unter der Menueleiste,
    /// und `visibleFrame.maxY` ist deren Unterkante.
    public static func anchorTop(measured: CGFloat?, visibleFrame: CGRect) -> CGFloat {
        measured ?? (visibleFrame.maxY - assumedGap)
    }

    /// Der neue Ursprung, damit die Oberkante bleibt, wo sie war.
    ///
    /// Ein `NSWindow` hat seinen Ursprung unten links. Eine Hoehenaenderung mit
    /// gleichem Ursprung schiebt deshalb die Oberkante, und genau das ist das
    /// Problem: Die Unterkante bleibt stehen, das Fenster waechst nach oben aus
    /// der Menueleiste heraus.
    ///
    /// Nach unten geklemmt: Mehrere aufgeklappte Abschnitte reichen zusammen
    /// unter den Bildschirmrand. Lieber ein Fenster, das unten anstoesst, als
    /// eines, dessen Fussleiste nicht mehr erreichbar ist.
    public static func origin(
        currentOrigin: CGPoint,
        height: CGFloat,
        anchorTop: CGFloat,
        visibleFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: currentOrigin.x,
            y: max(anchorTop - height, visibleFrame.minY)
        )
    }

    /// Lohnt die Verschiebung? Bruchteile eines Punktes nicht.
    ///
    /// Ohne diese Schwelle setzt jede Rundung einen neuen Frame, der wieder
    /// eine Benachrichtigung ausloest, die wieder einen Frame setzt.
    public static func worthMoving(from: CGPoint, to: CGPoint) -> Bool {
        abs(to.y - from.y) > 0.5
    }
}
