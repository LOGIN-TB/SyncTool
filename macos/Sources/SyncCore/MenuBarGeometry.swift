import CoreGraphics
import Foundation

/// Wohin ein Menueleisten-Fenster gehoert, wenn sein Inhalt die Hoehe aendert.
///
/// Reine Rechnung, damit sie sich pruefen laesst. Die Mechanik drumherum, also
/// welche Benachrichtigung wann kommt, steckt in `MenuBarWindowAnchor` und ist
/// von aussen nicht zu erreichen; genau dort sind schon mehrere Anlaeufe
/// gescheitert. Was sich rechnen laesst, soll deshalb nicht dort liegen.
public enum MenuBarGeometry {
    /// Abstand zur Menueleiste, wenn nichts gemessen wurde.
    ///
    /// Ein Ersatzwert, der nur greift, solange keine verlaessliche Oberkante
    /// vorliegt. Ohne ihn bliebe das Fenster in genau dem Fall unkorrigiert, in
    /// dem es am meisten wandert.
    ///
    /// Die 2 sind gemessen und nicht geraten: Ein Lauf mit einem Fenster
    /// derselben Bauart setzte die Oberkante auf `visibleFrame.maxY - 2`, und
    /// dieselbe Zahl stand im Protokoll des echten Popovers. Vorher stand hier
    /// eine 6, und das Fenster sass vier Punkte zu tief.
    public static let assumedGap: CGFloat = 2

    /// Bis hierher gilt eine Oberkante als "haengt an der Menueleiste".
    ///
    /// Zwei Aufgaben in einer Zahl. Sie erkennt das Menueleisten-Fenster: Was
    /// beim Erscheinen dicht unter der Menueleiste sitzt, ist eines, und was
    /// mitten auf dem Bildschirm steht, geht uns nichts an. Und sie macht die
    /// Sache selbstheilend: Haben wir einmal eine verrutschte Kante gemerkt,
    /// faellt sie beim naechsten Mal heraus, statt den Fehler festzuschreiben.
    ///
    /// 40 Punkt sind grosszuegig gegenueber den gemessenen 2 und immer noch
    /// weit von jeder Fensterlage entfernt, die nicht an der Menueleiste haengt.
    public static let maxGap: CGFloat = 40

    /// Haengt diese Oberkante an der Menueleiste?
    public static func hangsAtMenuBar(top: CGFloat, visibleFrame: CGRect) -> Bool {
        top <= visibleFrame.maxY + 1 && visibleFrame.maxY - top <= maxGap
    }

    /// Die Oberkante, an der das Fenster haengen soll.
    ///
    /// `measured` ist die Kante, die das System selbst gesetzt hat. Die ist
    /// richtig, sie stammt vom Statusitem. Fehlt sie oder liegt sie weit von
    /// der Menueleiste weg, haengt ein Menueleisten-Fenster trotzdem immer
    /// unmittelbar darunter, und `visibleFrame.maxY` ist deren Unterkante.
    public static func anchorTop(measured: CGFloat?, visibleFrame: CGRect) -> CGFloat {
        guard let measured, hangsAtMenuBar(top: measured, visibleFrame: visibleFrame) else {
            return visibleFrame.maxY - assumedGap
        }
        return measured
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
