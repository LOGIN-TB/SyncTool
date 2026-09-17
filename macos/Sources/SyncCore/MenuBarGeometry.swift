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

    /// Was Kopfzeile, Fusszeile und Raender vom Fenster belegen.
    ///
    /// Gemessen sind es rund 125 Punkt. Hier steht mehr, und zwar mit Absicht:
    /// Der Wert entscheidet nur darueber, ab wann der Mittelteil scrollt, und
    /// ein paar Punkte zu viel sind harmlos. Ein paar zu wenig waeren es nicht.
    public static let chromeHeight: CGFloat = 200

    /// So hoch ist der Mittelteil, sobald ein Pruefergebnis dasteht.
    ///
    /// 520 Punkt sind an den gemessenen Faellen ausgerichtet: Ein volles
    /// Pruefergebnis mit zugeklappten Abschnitten braucht rund 485 und bleibt
    /// damit ohne Rollbalken. Wer einen Abschnitt aufklappt, bekommt einen, und
    /// das ist gewollt. Ein Fenster, das stattdessen auf ueber 1300 Punkt
    /// waechst, ist keine Hilfe: Es laeuft oben aus dem Bildschirm, und dann
    /// ist der Pfeil zum Zuklappen nicht mehr da.
    public static let preferredContentHeight: CGFloat = 520

    /// Die groesste Hoehe, die der Mittelteil einnehmen darf.
    ///
    /// Das ist die eigentliche Erkenntnis aus der ganzen Geschichte. Das
    /// Fenster ist nie gewandert, weil eine Nachfuehrung fehlte, sondern weil
    /// es ueber den Bildschirm hinauswuchs: Aufgeklappte Abschnitte reichten
    /// zusammen weiter, als Platz war, und dann rueckt macOS das Fenster nach
    /// oben. Beim Zuklappen rueckt es nicht zurueck.
    ///
    /// Auf einem kleinen Bildschirm faellt die Grenze kleiner aus, nie aber
    /// unter 240: Ein Mittelteil, in dem nur noch zwei Zeilen stehen, waere
    /// keine Ansicht mehr.
    public static func maxContentHeight(visibleFrame: CGRect) -> CGFloat {
        min(preferredContentHeight, max(240, visibleFrame.height - chromeHeight))
    }

    /// Lohnt die Verschiebung? Bruchteile eines Punktes nicht.
    ///
    /// Ohne diese Schwelle setzt jede Rundung einen neuen Frame, der wieder
    /// eine Benachrichtigung ausloest, die wieder einen Frame setzt.
    public static func worthMoving(from: CGPoint, to: CGPoint) -> Bool {
        abs(to.y - from.y) > 0.5
    }
}
