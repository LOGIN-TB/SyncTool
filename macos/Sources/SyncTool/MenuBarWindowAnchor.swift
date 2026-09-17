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
/// Vier Anlaeufe sind hier gescheitert, und jeder an einer Annahme ueber etwas,
/// das niemand nachgesehen hatte.
///
/// Der erste hat den Abstand zur Menueleiste gemessen, bevor SwiftUI
/// positioniert hatte. Der zweite hing an `didMove` und `didBecomeKey`, die
/// beide ausbleiben koennen. Der dritte hing an einer nullgrossen
/// Hintergrundansicht, die nach dem ersten Einhaengen nichts mehr mitbekam.
///
/// Der vierte ist der lehrreiche: Er hoerte prozessweit zu, also an der
/// richtigen Stelle, erkannte das Fenster aber an `Breite == 460` und
/// `isVisible`. Im Protokoll stand danach keine einzige Nachfuehrung mehr,
/// waehrend der Anlauf davor wenigstens eine geschafft hatte. Beide Merkmale
/// waren geraten: `StatusView` ist 460 breit, das Fenster darum herum ist es
/// nicht zwingend, und wer sagt, dass SwiftUI erst einblendet und dann die
/// Groesse setzt.
///
/// Deshalb erkennt dieser Anlauf das Fenster an dem, was ein
/// Menueleisten-Fenster ausmacht und was wir selbst nachgemessen haben: Es hat
/// keinen Titelbalken, es ist kein Menue und nicht das Feld in der Leiste
/// selbst, es hat eine sinnvolle Groesse, und beim Erscheinen haengt es dicht
/// unter der Menueleiste. Keine feste Zahl, die eine Aenderung an der Ansicht
/// still ausser Kraft setzen koennte.
@MainActor
final class MenuBarWindowKeeper {
    private var observers: [any NSObjectProtocol] = []
    /// Je Fenster die Oberkante, an der es haengen soll.
    private var tops: [ObjectIdentifier: CGFloat] = [:]
    /// Fenster, die gerade von uns verschoben werden.
    private var pending: Set<ObjectIdentifier> = []
    /// Fenster, ueber die schon eine Zeile im Protokoll steht. Ohne das
    /// schriebe jede Groessenaenderung dieselbe Auskunft erneut.
    private var introduced: Set<ObjectIdentifier> = []
    /// Das Sicherheitsnetz. Siehe `startTimer`.
    private var timer: Timer?
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
        startTimer()
        log.write("Fensteranker läuft")
    }

    /// Schaut regelmaessig selbst nach, statt sich auf Benachrichtigungen zu
    /// verlassen.
    ///
    /// Der Grund steht oben: Vier Anlaeufe sind daran gescheitert, dass eine
    /// Benachrichtigung ausblieb oder ein Fenster nicht erkannt wurde, und
    /// jedes Mal sah es von aussen gleich aus, naemlich so, als passiere
    /// nichts. Ein Blick alle fuenf Zehntelsekunden kostet nichts und haengt an
    /// keiner Annahme darueber, was AppKit wann meldet.
    ///
    /// Die Benachrichtigungen bleiben trotzdem: Sie kommen sofort, und nur so
    /// sitzt das Fenster schon richtig, wenn es gezeichnet wird. Der Zeitgeber
    /// faengt den Rest.
    private func startTimer() {
        let zeitgeber = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        // `.common` und nicht `scheduledTimer`: Solange AppKit in einer eigenen
        // Ereignisschleife steht, etwa waehrend das Statusitem den Mausklick
        // verfolgt, feuert ein Timer im Standardmodus ueberhaupt nicht.
        // Nachgemessen an einem Versuchsaufbau, in dem genau das passierte.
        RunLoop.main.add(zeitgeber, forMode: .common)
        timer = zeitgeber
    }

    private func sweep() {
        for window in NSApp.windows {
            let id = ObjectIdentifier(window)
            guard !pending.contains(id) else { continue }
            guard window.isVisible else {
                // Zu heisst zu: Beim naechsten Oeffnen wird neu gemessen, und
                // das ist wichtig, wenn das Fenster dann auf einem anderen
                // Bildschirm aufgeht.
                tops.removeValue(forKey: id)
                continue
            }
            guard isCandidate(window) else { continue }
            if tops[id] == nil {
                remember(window)
            } else {
                realign(window)
            }
        }
    }

    /// Kommt dieses Fenster ueberhaupt in Frage?
    ///
    /// Bewusst ohne feste Breite. Ausgeschlossen wird, was sich sicher
    /// ausschliessen laesst: alles mit Titelbalken, also die Einstellungen und
    /// die Statusansicht als eigenes Fenster, dazu das Feld in der Leiste
    /// selbst und die Menues. Was dann noch uebrig ist und eine Groesse hat,
    /// bei der ein Verrutschen ueberhaupt auffiele, geht in die naechste
    /// Pruefung: Haengt es an der Menueleiste?
    private func isCandidate(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.titled) else { return false }
        let klasse = String(describing: type(of: window))
        guard !klasse.contains("StatusBar"), !klasse.contains("Menu") else { return false }
        return window.frame.width >= 200 && window.frame.height >= 60
    }

    /// Das System hat das Fenster gesetzt. Das ist die bessere Oberkante.
    ///
    /// Uebernommen wird sie nur, wenn sie an der Menueleiste haengt. Damit
    /// merkt sich der Anker keine Kante, die schon verrutscht ist, und ein
    /// Fenster, das dort nie hing, wird auch nie angefasst.
    private func remember(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard isCandidate(window), !pending.contains(id) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let top = window.frame.maxY
        guard MenuBarGeometry.hangsAtMenuBar(top: top, visibleFrame: screen.visibleFrame) else {
            introduce(window, angenommen: false)
            return
        }
        introduce(window, angenommen: true)
        tops[id] = top
    }

    private func realign(_ window: NSWindow) {
        guard isCandidate(window), let screen = window.screen ?? NSScreen.main else { return }
        let id = ObjectIdentifier(window)
        // Ohne gemerkte Oberkante nur dann, wenn das Fenster gerade noch an der
        // Menueleiste haengt. Sonst waere jedes rahmenlose Fenster dieser App
        // ein Kandidat, und der Anker zoege es unter die Leiste.
        if tops[id] == nil {
            guard
                MenuBarGeometry.hangsAtMenuBar(
                    top: window.frame.maxY, visibleFrame: screen.visibleFrame)
            else {
                introduce(window, angenommen: false)
                return
            }
            introduce(window, angenommen: true)
            tops[id] = window.frame.maxY
        }

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

    /// Eine Zeile je Fenster, damit im Fehlerfall dasteht, was der Anker
    /// gesehen und wie er sich entschieden hat.
    ///
    /// Das fehlte beim vierten Anlauf, und deshalb war aus dem Protokoll nur
    /// abzulesen, dass nichts passierte, nicht warum.
    private func introduce(_ window: NSWindow, angenommen: Bool) {
        let id = ObjectIdentifier(window)
        guard introduced.insert(id).inserted else { return }
        let f = window.frame
        log.write(
            "Fenster gesehen: \(type(of: window)) \(Int(f.width))×\(Int(f.height)) "
                + "Oberkante \(Int(f.maxY)), \(angenommen ? "angenommen" : "nicht an der Menüleiste")"
        )
    }
}
