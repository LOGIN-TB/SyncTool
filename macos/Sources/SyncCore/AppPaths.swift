import Foundation

/// Feste Ablageorte der App unter Application Support.
public enum AppPaths {
    public static let directoryName = "SyncTool"

    /// Umlenkung fuer Tests und die Bildschirmfoto-Werkstatt.
    ///
    /// Ohne diesen Schalter gibt es keinen Weg, die App gegen eine andere
    /// Konfiguration laufen zu lassen: `NSHomeDirectory()` kommt aus der
    /// Benutzerdatenbank und nicht aus `$HOME`, ein umgebogenes HOME wirkt also
    /// nicht. Wer Bildschirmfotos aufnimmt oder einen Ablauf von Hand erprobt,
    /// muesste sonst die echten Zugangsdaten anfassen.
    ///
    /// Ausdruecklich eine Umgebungsvariable und keine Einstellung: sie gilt nur
    /// fuer den einen Prozess, der sie mitbekommt, und niemand stolpert im
    /// Alltag darueber.
    public static let overrideVariable = "SYNCTOOL_SUPPORT_DIR"

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[overrideVariable],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var profilesFile: URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }

    public static var knownHostsFile: URL {
        supportDirectory.appendingPathComponent("known_hosts")
    }

    public static var privateKeyFile: URL {
        supportDirectory.appendingPathComponent("id_ed25519")
    }

    public static var publicKeyFile: URL {
        supportDirectory.appendingPathComponent("id_ed25519.pub")
    }

    /// Legt das Verzeichnis an, falls noetig, und schliesst andere Benutzer aus.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let url = supportDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return url
    }
}
