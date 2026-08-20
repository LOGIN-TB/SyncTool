import Foundation

public enum SSHSessionError: LocalizedError {
    case askpassMissing(String)
    case passwordMissing

    public var errorDescription: String? {
        switch self {
        case .askpassMissing(let path):
            return "Askpass-Helfer nicht gefunden (erwartet unter \(path)). App neu bauen mit `make app`."
        case .passwordMissing:
            return "Kein Passwort hinterlegt. In den Einstellungen eintragen und sichern."
        }
    }
}

/// Haelt alles zusammen, was ein einzelner ssh- oder rsync-Lauf an Zustand
/// braucht: Passwort-Socket, Wrapper-Skript fuer `rsync -e`, Umgebung.
/// Nach `stop()` bleibt nichts auf der Platte zurueck.
public final class SSHSession {
    public let profile: Profile
    private let directory: URL
    private var socket: PasswordSocket?
    private var remoteShell: URL?
    private let knownHosts: URL
    private let identity: URL

    public init(
        profile: Profile,
        knownHosts: URL = AppPaths.knownHostsFile,
        identity: URL = AppPaths.privateKeyFile
    ) throws {
        self.profile = profile
        self.knownHosts = knownHosts
        self.identity = identity
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.directory = base.appendingPathComponent(
            "synctool-" + UUID().uuidString.prefix(8), isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit { stop() }

    /// Ort des Askpass-Helfers. Im Bundle liegt er neben dem Hauptprogramm,
    /// bei `swift build` im selben Build-Verzeichnis.
    public static func askpassURL() throws -> URL {
        let candidates: [URL] = [
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("SyncToolAskpass"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("SyncToolAskpass"),
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw SSHSessionError.askpassMissing(candidates.first?.path ?? "unbekannt")
    }

    /// Startet den Passwort-Socket, falls das Profil auf Passwort steht.
    public func start(password: String?) throws {
        guard profile.authMode == .password else { return }
        guard let password, !password.isEmpty else { throw SSHSessionError.passwordMissing }
        let socket = try PasswordSocket(password: password, directory: directory)
        try socket.start()
        self.socket = socket
    }

    public func stop() {
        socket?.stop()
        socket = nil
        remoteShell = nil
        try? FileManager.default.removeItem(at: directory)
    }

    public var environment: [String: String] {
        get throws {
            // Ohne Passwort-Socket braucht ssh keinen Askpass-Helfer, dann darf
            // sein Fehlen auch kein Grund zum Abbruch sein.
            guard let socketPath = socket?.path else {
                return SSHCommand.environment(askpass: nil, passwordSocket: nil)
            }
            return SSHCommand.environment(
                askpass: try Self.askpassURL(), passwordSocket: socketPath
            )
        }
    }

    public func sshArguments(remoteCommand: [String] = []) -> [String] {
        SSHCommand.arguments(
            for: profile,
            remoteCommand: remoteCommand,
            knownHosts: knownHosts,
            identity: identity
        )
    }

    /// Pfad zum Wrapper-Skript, das rsync als Remote-Shell aufruft.
    public func remoteShellPath() throws -> String {
        if let remoteShell { return remoteShell.path }
        let script = SSHCommand.remoteShellScript(
            options: SSHCommand.options(for: profile, knownHosts: knownHosts, identity: identity)
        )
        let url = directory.appendingPathComponent("rsh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
        remoteShell = url
        return url.path
    }

    /// Meldet sich an und legt den Zielordner an, falls er fehlt. `mkdir -p`
    /// ist idempotent und gehoert zu dem, was der Nutzer mit dem Pfad meint.
    public func testConnection() async throws -> CommandResult {
        let path = profile.remotePath.hasSuffix("/")
            ? String(profile.remotePath.dropLast()) : profile.remotePath
        let command = "mkdir -p \(SSHCommand.shellQuote(path)) && echo synctool-ok"
        return try await CommandRunner.run(
            executable: SSHCommand.sshPath,
            arguments: sshArguments(remoteCommand: [command]),
            environment: try environment,
            timeout: 45
        )
    }

    /// Fuehrt ein Kommando auf dem Ziel aus, optional mit Eingabe auf stdin.
    public func runRemote(
        _ command: String,
        standardInput: String? = nil,
        timeout: TimeInterval = 45
    ) async throws -> CommandResult {
        try await CommandRunner.run(
            executable: SSHCommand.sshPath,
            arguments: sshArguments(remoteCommand: [command]),
            environment: try environment,
            standardInput: standardInput,
            timeout: timeout
        )
    }
}
