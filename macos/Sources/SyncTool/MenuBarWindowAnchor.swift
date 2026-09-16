import AppKit
import SwiftUI

/// Haelt das Menueleisten-Fenster unter seinem Symbol, wenn der Inhalt waechst.
///
/// `MenuBarExtra` im Fenster-Stil richtet sein Fenster nur beim Oeffnen am
/// Statusitem aus. Jede spaetere Hoehenaenderung kommt als `setFrame` mit
/// stehender Unterkante an, und weil ein `NSWindow` seinen Ursprung unten links
/// hat, wandert dabei die Oberkante nach oben. Ein Aufklappen der Repo-Liste
/// verschiebt das Fenster so um mehrere hundert Punkt.
///
/// Der Anker ist die Oberkante, die SwiftUI beim Oeffnen selbst gewaehlt hat.
/// Die ist richtig, sie stammt vom Statusitem; sie geht nur bei der naechsten
/// Groessenaenderung verloren. Gemerkt wird sie deshalb bei jeder Bewegung, die
/// nicht von uns kommt, und bei jeder Groessenaenderung wieder hergestellt.
///
/// Der erste Anlauf rechnete stattdessen mit dem Abstand zur Menueleiste, und
/// zwar gemessen in `viewDidMoveToWindow`. Zu dem Zeitpunkt hat SwiftUI das
/// Fenster noch nicht gesetzt: Der Abstand war Unsinn, die erste Korrektur
/// schob das Fenster an die falsche Stelle, und die naechste Messung nahm diese
/// Stelle fuer bare Muenze. Deshalb hier kein Messen mehr vor der ersten echten
/// Bewegung und kein Bezug auf den Bildschirm, wo einer auf das Fenster genuegt.
///
/// Die Breite bleibt unberuehrt. Sie aendert sich nie (`StatusView` steht auf
/// 460), also ist die waagerechte Lage nie in Gefahr.
private final class AnchorView: NSView {
    /// Die Oberkante, an der das Fenster haengen soll. `nil` heisst: SwiftUI
    /// hat noch nicht positioniert, also gibt es nichts zu halten.
    private var anchorTop: CGFloat?
    /// Zaehlt die Korrekturen, die noch unterwegs sind.
    ///
    /// Bewusst ein Zaehler und kein Schalter: Die Korrektur laeuft asynchron,
    /// und die Benachrichtigung ueber unsere eigene Bewegung trifft erst
    /// danach ein. Ein Schalter, der synchron wieder zurueckfaellt, waere zu
    /// dem Zeitpunkt schon offen, und wir haetten unsere eigene Bewegung fuer
    /// die von SwiftUI gehalten.
    private var pending = 0
    private var observers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unsubscribe()
        anchorTop = nil
        guard let window = self.window else { return }
        // Nur das rahmenlose Popover. Das Einstellungsfenster und das
        // Statusfenster der Bildschirmfoto-Werkstatt sind gewoehnliche Fenster
        // und werden nicht nachgefuehrt, auch wenn der Schalter je an der
        // falschen Stelle gesetzt wird.
        guard !window.styleMask.contains(.titled) else { return }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, self.pending == 0 else { return }
                // SwiftUI hat das Fenster gesetzt. Das ist die Wahrheit ueber
                // die Oberkante.
                self.anchorTop = window.frame.maxY
            },
            // Das Entscheidende, und der Grund, warum der erste Anlauf nie
            // gegriffen hat: `MenuBarExtra` legt sein Fenster nicht jedes Mal
            // neu an, es blendet dasselbe wieder ein. Steht es dabei schon an
            // der richtigen Stelle, kommt gar keine Bewegung, und ohne
            // Bewegung hatten wir nie eine Oberkante zu halten. Beim
            // Sichtbarwerden steht sie dagegen immer fest.
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.anchorTop = window.frame.maxY
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.realign(window)
            },
        ]

        // Und fuer den Fall, dass das Fenster schon steht, wenn diese Ansicht
        // eingehaengt wird. Eine Runde spaeter, weil SwiftUI zu diesem
        // Zeitpunkt noch nicht positioniert hat: Genau daran ist der erste
        // Anlauf gescheitert, der hier sofort gemessen hat.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.anchorTop == nil, window.isVisible else { return }
            self.anchorTop = window.frame.maxY
        }
    }

    deinit { unsubscribe() }

    private func unsubscribe() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func realign(_ window: NSWindow) {
        // Ohne Oberkante gibt es nichts zu halten. Sie hier zu nehmen waere
        // falsch: Die Groesse hat sich gerade geaendert, die Oberkante ist
        // also schon verschoben, und wir wuerden die Verschiebung festhalten,
        // die wir gerade rueckgaengig machen sollen.
        guard let anchorTop else { return }
        var origin = window.frame.origin
        origin.y = anchorTop - window.frame.height
        // Nach unten klemmen: `BoundedList` deckelt jede Liste einzeln, mehrere
        // aufgeklappte Abschnitte zusammen reichen aber unter den Bildschirm.
        // Lieber ein Fenster, das unten anstoesst, als eines, dessen Fussleiste
        // nicht mehr erreichbar ist.
        if let screen = window.screen ?? NSScreen.main {
            origin.y = max(origin.y, screen.visibleFrame.minY)
        }
        guard abs(origin.y - window.frame.origin.y) > 0.5 else { return }

        // Nicht synchron aus dem Benachrichtigungs-Handler heraus: Der laeuft
        // mitten in AppKits Groessenaenderung, waehrend SwiftUI sein Layout
        // rechnet. Ein `setFrameOrigin` an dieser Stelle greift in einen Lauf
        // ein, der noch nicht fertig ist. Eine Runde spaeter ist alles
        // abgeschlossen, und die Verschiebung faellt niemandem auf.
        pending += 1
        DispatchQueue.main.async { [weak self] in
            window.setFrameOrigin(origin)
            // Erst danach freigeben, sonst haelt der `didMove`-Beobachter
            // unsere eigene Bewegung fuer die von SwiftUI und merkt sich eine
            // Oberkante, die wir gerade selbst gesetzt haben.
            DispatchQueue.main.async { self?.pending -= 1 }
        }
    }
}

private struct MenuBarWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

extension View {
    /// Haelt das umgebende Menueleisten-Fenster unter seinem Symbol.
    ///
    /// Bei `false` bleibt die Ansicht unveraendert, damit dieselbe Ansicht in
    /// einer gewoehnlichen Fensterszene nichts davon mitbekommt.
    @ViewBuilder
    func anchoredBelowMenuBar(_ active: Bool) -> some View {
        if active {
            background(MenuBarWindowAnchor().frame(width: 0, height: 0))
        } else {
            self
        }
    }
}
