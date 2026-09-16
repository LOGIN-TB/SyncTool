import AppKit
import SwiftUI

/// Haelt das Menueleisten-Fenster unter seinem Symbol, wenn der Inhalt waechst.
///
/// `MenuBarExtra` im Fenster-Stil richtet sein Fenster nur beim Oeffnen am
/// Statusitem aus. Jede spaetere Hoehenaenderung kommt als `setFrame` mit
/// stehender Unterkante an, und weil ein `NSWindow` seinen Ursprung unten links
/// hat, wandert dabei die Oberkante nach oben. Ein Aufklappen der Repo-Liste
/// verschiebt das Fenster so um mehrere hundert Punkt, und es haengt danach
/// nicht mehr unter dem Symbol.
///
/// Der Anker muss dafuer nicht am Statusitem gesucht werden, und das ist der
/// Punkt: Ein Menueleisten-Fenster haengt immer unmittelbar unter der
/// Menueleiste, und deren Unterkante ist `screen.visibleFrame.maxY`. Oeffentlich,
/// ohne privaten Klassennamen und ohne Suche durch `NSApp.windows`.
///
/// Der zusaetzliche Abstand, den SwiftUI laesst, wird beim Oeffnen einmal
/// gemessen. Das Verfahren ist damit selbstheilend: Stimmt der gemerkte Abstand
/// einmal nicht, ist der Fehler ein paar Punkte gross statt mehrere hundert,
/// weil der Bezug bei jeder Korrektur frisch vom Bildschirm kommt.
///
/// Die Breite bleibt unberuehrt. Sie aendert sich nie (`StatusView` steht auf
/// 460), also ist die waagerechte Lage nie in Gefahr.
private final class AnchorView: NSView {
    /// Abstand zwischen Menueleisten-Unterkante und Fensteroberkante, beim
    /// Oeffnen gemessen. `nil` heisst: noch nie gesehen.
    private var gap: CGFloat?
    /// Sperrt den Wiedereintritt: Unser eigenes `setFrameOrigin` loest wieder
    /// eine Benachrichtigung aus.
    private var correcting = false
    private var observers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unsubscribe()
        guard let window = self.window else { return }
        // Nur das rahmenlose Popover. Das Einstellungsfenster und das
        // Statusfenster der Bildschirmfoto-Werkstatt sind gewoehnliche Fenster
        // und werden nicht nachgefuehrt, auch wenn der Schalter je an der
        // falschen Stelle gesetzt wird.
        guard !window.styleMask.contains(.titled) else { return }

        measure(window)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, !self.correcting else { return }
                // Hat SwiftUI das Fenster selbst gesetzt, ist das der neue
                // gueltige Abstand.
                self.measure(window)
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.realign(window)
            },
        ]
    }

    deinit { unsubscribe() }

    private func unsubscribe() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func screen(for window: NSWindow) -> NSScreen? {
        window.screen ?? NSScreen.main
    }

    private func measure(_ window: NSWindow) {
        guard let screen = screen(for: window) else { return }
        gap = screen.visibleFrame.maxY - window.frame.maxY
    }

    private func realign(_ window: NSWindow) {
        guard let gap, let screen = screen(for: window), !correcting else { return }
        var origin = window.frame.origin
        origin.y = screen.visibleFrame.maxY - gap - window.frame.height
        // Nach unten klemmen: `BoundedList` deckelt jede Liste einzeln, mehrere
        // aufgeklappte Abschnitte zusammen reichen aber unter den Bildschirm.
        // Lieber ein Fenster, das unten anstoesst, als eines, dessen Fussleiste
        // nicht mehr erreichbar ist.
        origin.y = max(origin.y, screen.visibleFrame.minY)
        guard abs(origin.y - window.frame.origin.y) > 0.5 else { return }
        correcting = true
        window.setFrameOrigin(origin)
        correcting = false
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
