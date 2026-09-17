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
/// Fuenf Anlaeufe sind hier gescheitert, und die Reihenfolge ist lehrreich:
///
///  1. Der Abstand zur Menueleiste wurde gemessen, bevor SwiftUI positioniert
///     hatte. Die erste Korrektur machte den falschen Wert zur Wahrheit.
///  2. Der Anker wartete auf `didMove` und `didBecomeKey`. Beide koennen
///     ausbleiben, und dann wurde nie korrigiert.
///  3. Der Anker hing an einer nullgrossen Hintergrundansicht. Sie wurde einmal
///     eingehaengt, danach kam keine Groessenaenderung mehr an.
///  4. Der Anker hoerte prozessweit zu, erkannte das Fenster aber an
///     `Breite == 460`.
///  5. Er erkannte es an `kein Titelbalken` und daran, dass der Klassenname
///     weder "StatusBar" noch "Menu" enthaelt.
///
/// Vier und fuenf sind derselbe Fehler: eine Eigenschaft raten, statt sie
/// nachzusehen. Deshalb entscheidet hier nur noch Geometrie, und die ist
/// nachgemessen. Ein Menueleisten-Fenster ist gross genug, dass ein Verrutschen
/// auffiele, und seine Oberkante haengt beim Erscheinen an der Menueleiste.
/// Alles andere, vom Feld in der Leiste bis zu den eigenen Fenstern der App,
/// faellt allein dadurch heraus.
///
/// Und weil aus dem Protokoll bisher nur abzulesen war, dass nichts passierte,
/// schreibt der Anker jetzt jede Fensterliste mit, sobald sich etwas an ihr
/// aendert: mit Klasse, Kennung, Stilmaske, Lage und Entscheidung. Wer das
/// naechste Mal hier steht, muss nicht mehr raten.
@MainActor
final class MenuBarWindowKeeper {
    /// Fenster, die SwiftUI aus den `Window`-Szenen baut. Die gehoeren nicht
    /// unter die Menueleiste, auch wenn jemand sie dorthin schiebt.
    static let ownSceneIdentifiers: Set<String> = ["settings", "status"]

    private var observers: [any NSObjectProtocol] = []
    /// Je Fenster die Oberkante, an der es haengen soll.
    private var tops: [ObjectIdentifier: CGFloat] = [:]
    /// Fenster, die gerade von uns verschoben werden.
    private var pending: Set<ObjectIdentifier> = []
    /// Die Fensterlage beim letzten Bericht. Aendert sie sich, wird berichtet.
    private var lastReport = ""
    private var timer: Timer?
    /// Das Fenster, das die Statusansicht selbst gemeldet hat. Siehe `adopt`.
    private weak var adopted: NSWindow?
    private let log = RunLog()

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // `object: nil`: alle Fenster dieses Prozesses. Welches gemeint ist,
        // entscheidet `isCandidate`, und nicht die Frage, wer sich gerade
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
    /// Der Grund steht oben: Mehrere Anlaeufe sind daran gescheitert, dass eine
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

    /// Nimmt das Fenster entgegen, in dem die Statusansicht wirklich steckt.
    ///
    /// Das ist der einzige Weg, der nichts raet. Die Ansicht weiss, in welchem
    /// Fenster sie haengt, und sagt es hier. Alles davor hat versucht, dieses
    /// Fenster von aussen wiederzuerkennen, an der Breite, an der Stilmaske, am
    /// Klassennamen, und jedes dieser Merkmale war falsch geraten.
    ///
    /// Der vorherige Anlauf hatte diese Auskunft schon und hat sie nur nicht
    /// genutzt: Er haengte seine Beobachter an die Ansicht, und die bekam nach
    /// dem ersten Einhaengen nichts mehr mit. Gemeldet wird das Fenster,
    /// nachgefuehrt wird es vom Zeitgeber.
    func adopt(_ window: NSWindow) {
        guard adopted !== window else { return }
        adopted = window
        let f = window.frame
        log.write(
            "Fenster gemeldet: \(type(of: window)) "
                + "[\(window.identifier?.rawValue ?? "-")] maske=\(window.styleMask.rawValue) "
                + "\(Int(f.width))×\(Int(f.height)) oben=\(Int(f.maxY))"
        )
    }

    private func sweep() {
        report()
        // Das gemeldete Fenster zuerst, und danach kein zweites Mal. Der Rest
        // der Liste ist das Netz fuer den Fall, dass die Meldung ausbleibt.
        var gesehen: Set<ObjectIdentifier> = []
        if let window = adopted {
            gesehen.insert(ObjectIdentifier(window))
            pruefe(window)
        }
        for window in NSApp.windows where !gesehen.contains(ObjectIdentifier(window)) {
            pruefe(window)
        }
    }

    private func pruefe(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard !pending.contains(id) else { return }
        guard window.isVisible else {
            // Zu heisst zu: Beim naechsten Oeffnen wird neu gemessen, und das
            // ist wichtig, wenn das Fenster dann auf einem anderen Bildschirm
            // aufgeht.
            tops.removeValue(forKey: id)
            return
        }
        guard isCandidate(window) else { return }
        if tops[id] == nil {
            remember(window)
        } else {
            realign(window)
        }
    }

    /// Kommt dieses Fenster ueberhaupt in Frage?
    ///
    /// Nur Groesse und Herkunft, keine Stilmaske und kein Klassenname. Beides
    /// war geraten und beides hat den Anker blind gemacht. Was zu klein ist,
    /// um beim Verrutschen aufzufallen, faellt heraus; dazu gehoert das Feld in
    /// der Menueleiste selbst mit seinen 32 auf 30 Punkt. Die eigentliche
    /// Pruefung ist die naechste: Haengt die Oberkante an der Menueleiste?
    private func isCandidate(_ window: NSWindow) -> Bool {
        if window === adopted { return true }
        if let kennung = window.identifier?.rawValue,
            Self.ownSceneIdentifiers.contains(kennung)
        {
            return false
        }
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
        guard MenuBarGeometry.hangsAtMenuBar(top: top, visibleFrame: screen.visibleFrame)
        else { return }
        tops[id] = top
    }

    private func realign(_ window: NSWindow) {
        guard isCandidate(window), let screen = window.screen ?? NSScreen.main else { return }
        let id = ObjectIdentifier(window)
        // Ohne gemerkte Oberkante nur dann, wenn das Fenster gerade noch an der
        // Menueleiste haengt. Sonst waere jedes Fenster dieser App ein
        // Kandidat, und der Anker zoege es unter die Leiste.
        if tops[id] == nil {
            guard
                MenuBarGeometry.hangsAtMenuBar(
                    top: window.frame.maxY, visibleFrame: screen.visibleFrame)
            else { return }
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

    /// Schreibt die Fensterlage mit, sobald sie sich aendert.
    ///
    /// Das ist die Zeile, die vier Anlaeufe lang gefehlt hat. Ohne sie stand im
    /// Protokoll nur, dass nichts passierte, und nicht, was der Anker gesehen
    /// und warum er es liegengelassen hat. Berichtet wird nur bei Aenderung,
    /// sonst schriebe der Zeitgeber fuenfmal in der Sekunde dasselbe.
    private func report() {
        var zeilen: [String] = []
        for window in NSApp.windows {
            let f = window.frame
            let kennung = window.identifier?.rawValue ?? "-"
            let haengt =
                (window.screen ?? NSScreen.main).map {
                    MenuBarGeometry.hangsAtMenuBar(top: f.maxY, visibleFrame: $0.visibleFrame)
                } ?? false
            let urteil: String
            if !window.isVisible {
                urteil = "zu"
            } else if !isCandidate(window) {
                urteil = "kein Kandidat"
            } else if !haengt && tops[ObjectIdentifier(window)] == nil {
                urteil = "nicht an der Menüleiste"
            } else {
                urteil = "angenommen"
            }
            zeilen.append(
                "\(type(of: window)) [\(kennung)] maske=\(window.styleMask.rawValue) "
                    + "lvl=\(window.level.rawValue) \(Int(f.width))×\(Int(f.height)) "
                    + "oben=\(Int(f.maxY)) → \(urteil)"
            )
        }
        let bericht = zeilen.joined(separator: " | ")
        guard bericht != lastReport else { return }
        lastReport = bericht
        log.write("Fenster: \(zeilen.isEmpty ? "keine" : bericht)")
    }
}


/// Sagt dem Anker, in welchem Fenster die Statusansicht steckt.
///
/// Nullgross und ohne eigene Darstellung. Die Ansicht hat diese Auskunft
/// umsonst, und sie ist die einzige, die nicht geraten ist: `self.window` ist
/// das Fenster, in dem sie haengt, ohne Umweg ueber Breite, Stilmaske oder
/// Klassennamen.
///
/// Nur melden, nicht nachfuehren. Genau daran ist ein frueherer Anlauf
/// gescheitert: Er hat hier auch beobachtet, und diese Ansicht bekam nach dem
/// ersten Einhaengen keine Groessenaenderung mehr mit.
struct MenuBarWindowReporter: NSViewRepresentable {
    let keeper: MenuBarWindowKeeper

    func makeNSView(context: Context) -> NSView { ReporterView(keeper: keeper) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReporterView)?.melden()
    }

    final class ReporterView: NSView {
        private let keeper: MenuBarWindowKeeper

        init(keeper: MenuBarWindowKeeper) {
            self.keeper = keeper
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("nicht aus einer Datei") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            melden()
        }

        func melden() {
            guard let window else { return }
            MainActor.assumeIsolated { keeper.adopt(window) }
        }
    }
}
