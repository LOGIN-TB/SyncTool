import Foundation

@testable import SyncCore

/// Welches rsync auf diesem Rechner fuer Tests taugt.
///
/// Einige Integrationstests brauchen ein rsync 3.x: nur das kennt `%C` fuer
/// Pruefsummen und gibt mit `-8` unmaskierte Namen aus. `/usr/bin/rsync` ist auf
/// aktuellem macOS openrsync und kann beides nicht.
///
/// Vorher stand der Pfad `/opt/homebrew/bin/rsync` an fuenfzehn Stellen fest im
/// Testcode. Damit liefen die Tests nur auf einem Rechner mit Homebrew, und auf
/// jedem anderen, auch auf dem CI-Laeufer, scheiterten neun Tests mit
/// "The file rsync doesn't exist" statt uebersprungen zu werden. Gefunden hat
/// das der erste CI-Lauf.
enum TestRsync {
    /// Der erste gefundene Kandidat, der nicht das openrsync des Systems ist.
    /// `nil` heisst: auf diesem Rechner nicht vorhanden.
    static let three: String? = RsyncLocator.searchPaths
        .filter { $0 != systemRsync }
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Das rsync, das macOS mitbringt. Seit Sequoia openrsync.
    static let systemRsync = "/usr/bin/rsync"

    /// Nur zusammen mit `.enabled(if: TestRsync.hasThree)` benutzen: ohne die
    /// Bedingung liefe der Test in einen Pfad, den es nicht gibt.
    static var threePath: String { three ?? "/opt/homebrew/bin/rsync" }

    static var hasThree: Bool { three != nil }
}
