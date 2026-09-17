import AppKit
import SwiftUI
import SyncCore

/// Haelt das Menueleisten-Fenster unter seinem Symbol, wenn der Inhalt waechst.
///
/// `MenuBarExtra` im Fenster-Stil richtet sein Fenster nur beim Oeffnen am
/// Statusitem aus. Jede spaetere Hoehenaenderung kommt als `setFrame` mit
/// stehendem Ursprung an, und weil ein `NSWindow` seinen Ursprung unten links
/// hat, wandert dabei die Oberkante nach oben. Aufklappen der Repo-Liste
/// verschiebt das Fenster so um mehrere hundert Punkt.
///
/// Zwei Anlaeufe sind hier gescheitert, und beide am selben Punkt: Sie hingen
/// davon ab, dass eine bestimmte Benachrichtigung kommt.
///
/// Der erste hat den Abstand zur Menueleiste in `viewDidMoveToWindow` gemessen.
/// Da hat SwiftUI noch nicht positioniert, der Wert war Unsinn, und die erste
/// Korrektur machte ihn zur Wahrheit.
///
/// Der zweite hat auf `didMove` und `didBecomeKey` gewartet. `didMove` kommt
/// nicht, wenn das wiederverwendete Fenster schon an der richtigen Stelle
/// steht, und `didBecomeKey` kommt bei einem nicht aktivierenden Panel gar
/// nicht. Ohne Oberkante wurde nie korrigiert, und genau das war die Meldung:
/// beim Oeffnen richtig, beim Aufklappen verrutscht.
///
/// Deshalb jetzt ohne Bedingung: Die gemessene Kante ist die bessere Quelle,
/// aber wenn keine vorliegt, rechnet `MenuBarGeometry` mit der Menueleiste.
/// Ein Menueleisten-Fenster haengt immer unmittelbar darunter. Damit wird in
/// jedem Fall korrigiert, schlimmstenfalls um ein paar Punkte ungenau.
private final class AnchorView: NSView {
    /// Die vom System gesetzte Oberkante, sofern wir eine gesehen haben.
    private var measuredTop: CGFloat?
    /// Zaehlt die Korrekturen, die noch unterwegs sind.
    ///
    /// Ein Zaehler und kein Schalter: Die Korrektur laeuft asynchron, und die
    /// Benachrichtigung ueber unsere eigene Bewegung trifft erst danach ein.
    private var pending = 0
    private var observers: [any NSObjectProtocol] = []
    private let log = RunLog()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unsubscribe()
        measuredTop = nil
        guard let window = self.window else { return }
        // Nur das rahmenlose Popover. Das Einstellungsfenster und das
        // Statusfenster der Bildschirmfoto-Werkstatt sind gewoehnliche Fenster.
        guard !window.styleMask.contains(.titled) else { return }

        let center = NotificationCenter.default
        // Jede Gelegenheit, an der das System die Lage selbst bestimmt hat.
        // Keine davon ist zugesichert, deshalb hoeren wir auf alle drei und
        // kommen zugleich ohne jede davon aus.
        let quellen: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        observers = quellen.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self, self.pending == 0, window.isVisible else { return }
                self.measuredTop = window.frame.maxY
            }
        }
        observers.append(
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.realign(window)
            }
        )
    }

    deinit { unsubscribe() }

    private func unsubscribe() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func realign(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let anchorTop = MenuBarGeometry.anchorTop(
            measured: measuredTop, visibleFrame: screen.visibleFrame
        )
        let ziel = MenuBarGeometry.origin(
            currentOrigin: window.frame.origin,
            height: window.frame.height,
            anchorTop: anchorTop,
            visibleFrame: screen.visibleFrame
        )
        guard MenuBarGeometry.worthMoving(from: window.frame.origin, to: ziel) else { return }

        // Die Oberkante gilt weiter, auch wenn wir sie gerade selbst herstellen.
        // Sonst waere sie nach dem ersten Ersatzwert dauerhaft der Ersatzwert.
        measuredTop = anchorTop
        log.write(
            "Fenster nachgeführt: Höhe \(Int(window.frame.height)), "
                + "Oberkante \(Int(anchorTop)), y \(Int(window.frame.origin.y)) → \(Int(ziel.y))"
        )

        // Nicht synchron aus dem Benachrichtigungs-Handler: Der laeuft mitten
        // in AppKits Groessenaenderung, waehrend SwiftUI sein Layout rechnet.
        pending += 1
        DispatchQueue.main.async { [weak self] in
            window.setFrameOrigin(ziel)
            // Erst danach freigeben, sonst haelt der Beobachter unsere eigene
            // Bewegung fuer die des Systems.
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
