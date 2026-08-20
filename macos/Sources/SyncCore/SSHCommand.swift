import Foundation

/// Baut die ssh-Optionen. Reine Funktionen, damit die Tests die Kommandozeile
/// pruefen koennen, ohne etwas zu starten.
public enum SSHCommand {
    public static let sshPath = "/usr/bin/ssh"
    public static let keyscanPath = "/usr/bin/ssh-keyscan"
    public static let keygenPath = "/usr/bin/ssh-keygen"

    /// Optionen ohne Ziel und ohne Kommando.
    public static func options(
        for profile: Profile,
        knownHosts: URL = AppPaths.knownHostsFile,
        identity: URL = AppPaths.privateKeyFile
    ) -> [String] {
        var args = [
            "-p", String(profile.port),
            // ssh liest den Wert als Liste von Dateien, getrennt durch
            // Leerzeichen. "Application Support" zerfiele sonst in zwei Pfade,
            // die es beide nicht gibt, und jede Host-Key-Prüfung schlüge fehl.
            "-o", "UserKnownHostsFile=\(optionValue(knownHosts.path))",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        switch profile.authMode {
        case .password:
            // Ohne diese Einschraenkung probiert ssh erst Agent-Keys durch und
            // laeuft je nach Server in MaxAuthTries, bevor das Passwort drankommt.
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "BatchMode=no",
            ]
        case .publicKey:
            args += [
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
                "-i", identity.path,
            ]
        }
        return args
    }

    /// Vollstaendiger ssh-Aufruf inklusive Ziel, fuer Verbindungstest und Key-Setup.
    public static func arguments(
        for profile: Profile,
        remoteCommand: [String] = [],
        knownHosts: URL = AppPaths.knownHostsFile,
        identity: URL = AppPaths.privateKeyFile
    ) -> [String] {
        var args = options(for: profile, knownHosts: knownHosts, identity: identity)
        args.append("\(profile.user)@\(profile.host)")
        args += remoteCommand
        return args
    }

    /// Umgebung fuer ssh und alles, was ssh startet.
    public static func environment(
        askpass: URL?,
        passwordSocket: String?
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let passwordSocket, let askpass {
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["SYNCTOOL_PW_SOCK"] = passwordSocket
            // Aeltere OpenSSH-Versionen verlangen ein gesetztes DISPLAY,
            // bevor sie ueberhaupt nach SSH_ASKPASS schauen.
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        } else {
            env.removeValue(forKey: "SSH_ASKPASS")
            env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
            env.removeValue(forKey: "SYNCTOOL_PW_SOCK")
        }
        // Ein laufender Agent wuerde im Passwortmodus fremde Keys anbieten.
        if askpassRequiresCleanAgent { env.removeValue(forKey: "SSH_AUTH_SOCK") }
        return env
    }

    private static let askpassRequiresCleanAgent = true

    /// Inhalt des Wrapper-Skripts fuer `rsync -e`.
    ///
    /// rsync zerlegt den `-e`-String selbst an Leerzeichen und kennt keine
    /// Anfuehrungszeichen. Da unsere Pfade unter "Application Support" ein
    /// Leerzeichen enthalten, geht das nur ueber ein Skript.
    public static func remoteShellScript(options: [String]) -> String {
        var lines = ["#!/bin/sh", "exec \(shellQuote(sshPath)) \\"]
        for option in options {
            lines.append("  \(shellQuote(option)) \\")
        }
        lines.append("  \"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wert für ein `-o`-Argument. ssh zerlegt Werte mancher Optionen selbst an
    /// Leerzeichen; doppelte Anführungszeichen halten den Pfad zusammen.
    public static func optionValue(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}
