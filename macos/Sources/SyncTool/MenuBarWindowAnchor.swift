import AppKit
import SwiftUI
import SyncCore

/// Haelt das Menueleisten-Fenster unter seinem Symbol, wenn der Inhalt waechst.
///
/// `MenuBarExtra` im Fenster-Stil richtet sein Fenster nur beim Oeffnen am
/// Statusitem aus. Jede spaetere Hoehenaenderung kommt als `setFrame` mit
/// stehendem Ursprung an, und weil ein `NSWindow` seinen Ursprung unten links
/// hat, wandert dabei die Oberkante nach oben.
///
/// Drei Anlaeufe sind hier gescheitert, und alle drei an derselben Annahme:
/// dass sich das Fenster ueber die SwiftUI-Ansicht erreichen laesst, die darin
/// liegt.
///
/// Der erste hat den Abstand zur Menueleiste gemessen, bevor SwiftUI
/// positioniert hatte. Der zweite hing an `didMove` und `didBecomeKey`, die
/// beide ausbleiben koennen. Der dritte hing an einer nullgrossen
/// Hintergrundansicht: Die wurde einmal eingehaengt, danach kam keine einzige
/// Groessenaenderung mehr an, obwohl das Fenster von 164 auf ueber 700 Punkt
/// wuchs. Im Protokoll stand genau eine Nachfuehrung.
///
/// Deshalb haengt hier nichts mehr an einer Ansicht. Ein Beobachter fuer alle
/// Fenster dieses Prozesses, angemeldet beim Start und bis zum Ende da. Er
/// fasst nur an, was er sicher erkennt: ein rahmenloses Fenster in der Breite
/// der Statusansicht. Das ist eng genug, dass kein Menue und kein Hinweisfeld
/// darunter faellt, und es haelt auch dann, wenn SwiftUI seine Ansichten neu
/// aufbaut.
@MainActor
final class MenuBarWindowKeeper {
    /// Die Breite, an der die Statusansicht zu erkennen ist. Sie ist fest, und
    /// genau deshalb taugt sie als Merkmal.
    static let windowWidth: CGFloat = 460

    private var observers: [any NSObjectProtocol] = []
    /// Je Fenster die Oberkante, an der es haengen soll.
    private var tops: [ObjectIdentifier: CGFloat] = [:]
    /// Fenster, die gerade von uns verschoben werden.
    private var pending: Set<ObjectIdentifier> = []
    private let log = RunLog()

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // `object: nil`: alle Fenster dieses Prozesses. Welches gemeint ist,
        // entscheidet `isStatusWindow`, und nicht die Frage, wer sich gerade
        // angemeldet hat.
        observers = [
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.realign(window) }
            },
            center.addObserver(
                forName: NSWindow.didMoveNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.remember(window) }
            },
            // Damit die Oberkante schon feststeht, bevor die erste
            // Groessenaenderung kommt. `didMove` bleibt aus, wenn das Fenster
            // an seiner Stelle eingeblendet wird, und dann waere die erste
            // Korrektur auf den Ersatzwert angewiesen.
            center.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.remember(window) }
            },
        ]
    }

    /// Erkennt die Statusansicht an dem, was sich nicht aendert.
    private func isStatusWindow(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.titled)
            && abs(window.frame.width - Self.windowWidth) < 1
            && window.isVisible
    }

    /// Das System hat das Fenster gesetzt. Das ist die bessere Oberkante.
    private func remember(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard isStatusWindow(window), !pending.contains(id) else { return }
        tops[id] = window.frame.maxY
    }

    private func realign(_ window: NSWindow) {
        guard isStatusWindow(window), let screen = window.screen ?? NSScreen.main else { return }
        let id = ObjectIdentifier(window)
        // Ab hier ist die Oberkante des Fensters nicht mehr die gewollte: Die
        // Groesse hat sich gerade geaendert. Sofort sperren, sonst schreibt ein
        // `didUpdate` dazwischen die verschobene Kante fest.
        pending.insert(id)
        let anchorTop = MenuBarGeometry.anchorTop(
            measured: tops[id], visibleFrame: screen.visibleFrame
        )
        let ziel = MenuBarGeometry.origin(
            currentOrigin: window.frame.origin,
            height: window.frame.height,
            anchorTop: anchorTop,
            visibleFrame: screen.visibleFrame
        )
        guard MenuBarGeometry.worthMoving(from: window.frame.origin, to: ziel) else {
            // Nichts zu tun, also darf wieder mitgeschrieben werden.
            pending.remove(id)
            return
        }

        // Die Oberkante gilt weiter, auch wenn wir sie gerade selbst
        // herstellen. Sonst waere sie nach dem ersten Ersatzwert dauerhaft der
        // Ersatzwert.
        tops[id] = anchorTop
        log.write(
            "Fenster nachgeführt: Höhe \(Int(window.frame.height)), "
                + "Oberkante \(Int(anchorTop)), y \(Int(window.frame.origin.y)) → \(Int(ziel.y))"
        )

        // Nicht synchron aus dem Benachrichtigungs-Handler: Der laeuft mitten
        // in AppKits Groessenaenderung, waehrend SwiftUI sein Layout rechnet.
        DispatchQueue.main.async { [weak self] in
            window.setFrameOrigin(ziel)
            DispatchQueue.main.async { self?.pending.remove(id) }
        }
    }
}
