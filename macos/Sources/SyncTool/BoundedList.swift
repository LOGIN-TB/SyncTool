import SwiftUI

/// Eine Liste, die ab einer gewissen Laenge eine eigene Scrollflaeche bekommt.
///
/// Ohne Begrenzung waechst das Fenster mit einem aufgeklappten Abschnitt ueber
/// den Bildschirmrand hinaus. Kurze Listen bekommen bewusst keine: eine
/// halbleere Scrollflaeche mit Rollbalken sieht aus wie ein Fehler.
///
/// Die Schwelle kommt aus der Zeilenhoehe des jeweiligen Abschnitts, nicht aus
/// einer festen Anzahl: Konfliktzeilen sind doppelt so hoch wie Pfadzeilen, und
/// eine Liste, die knapp ueber die Schwelle rutscht, braucht den Rollbalken
/// nicht.
///
/// Nur noch im Einstellungsfenster. Die Statusansicht hat das aufgegeben: Dort
/// scrollt der ganze Mittelteil, und eine Scrollflaeche in einer Scrollflaeche
/// ergibt zwei Rollbalken uebereinander. Das ist auf macOS eine Zumutung, und
/// zu Recht beanstandet worden. Hier passt es, weil das Einstellungsfenster
/// selbst nicht scrollt.
struct BoundedList<Content: View>: View {
    let count: Int
    /// Ungefaehre Hoehe einer Zeile in Punkten.
    let rowHeight: CGFloat
    @ViewBuilder let content: () -> Content

    /// Hoeher als das wird kein Abschnitt. Das Fenster bleibt damit auch mit
    /// zwei aufgeklappten Listen unter jeder Bildschirmhoehe.
    private static var maxHeight: CGFloat { 220 }

    private var scrolls: Bool { CGFloat(count) * rowHeight > Self.maxHeight }

    /// Auf ganze Zeilen abgerundet, damit die Scrollflaeche nicht mitten durch
    /// eine Zeile schneidet.
    private var height: CGFloat {
        max(rowHeight, (Self.maxHeight / rowHeight).rounded(.down) * rowHeight)
    }

    var body: some View {
        if scrolls {
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            content()
        }
    }
}
