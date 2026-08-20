import Foundation

public enum SSHKeySetupError: LocalizedError {
    case keygenFailed(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keygenFailed(let detail): return "Schlüsselpaar ließ sich nicht erzeugen: \(detail)"
        case .installFailed(let detail): return "Schlüssel ließ sich nicht hinterlegen: \(detail)"
        }
    }
}

/// Legt einmalig einen ed25519-Schluessel an und spielt ihn auf dem Ziel ein.
/// Danach laeuft der Sync ohne Passwort, was den Askpass-Weg und die
/// Verzoegerung beim Anmelden erspart.
public struct SSHKeySetup {
    private let privateKey: URL
    private let publicKey: URL

    public init(
        privateKey: URL = AppPaths.privateKeyFile,
        publicKey: URL = AppPaths.publicKeyFile
    ) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public var keyExists: Bool {
        FileManager.default.fileExists(atPath: privateKey.path)
            && FileManager.default.fileExists(atPath: publicKey.path)
    }

    public func publicKeyText() throws -> String {
        try String(contentsOf: publicKey, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func ensureKeyPair(comment: String) async throws -> String {
        if keyExists { return try publicKeyText() }

        try AppPaths.ensureSupportDirectory()
        try? FileManager.default.removeItem(at: privateKey)
        try? FileManager.default.removeItem(at: publicKey)

        let result = try await CommandRunner.run(
            executable: SSHCommand.keygenPath,
            arguments: [
                "-t", "ed25519",
                "-N", "",
                "-C", comment,
                "-f", privateKey.path,
            ],
            timeout: 60
        )
        guard result.succeeded else { throw SSHKeySetupError.keygenFailed(result.errorSummary) }

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: privateKey.path
        )
        return try publicKeyText()
    }

    /// Spielt den Public Key ein. Hetzner Storage Boxen kennen dafuer
    /// `install-ssh-key`; auf allen anderen Zielen wird an authorized_keys
    /// angehaengt, ohne vorhandene Eintraege zu verlieren.
    public func install(using session: SSHSession, isStorageBox: Bool) async throws {
        let key = try publicKeyText()

        if isStorageBox {
            let result = try await session.runRemote("install-ssh-key", standardInput: key + "\n")
            if result.succeeded { return }
            // Faellt durch: nicht jede Box hat das Kommando.
        }

        let appended = """
            mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
            touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
            grep -qxF \(SSHCommand.shellQuote(key)) ~/.ssh/authorized_keys || \
            printf '%s\\n' \(SSHCommand.shellQuote(key)) >> ~/.ssh/authorized_keys
            """
        let result = try await session.runRemote(appended)
        guard result.succeeded else {
            throw SSHKeySetupError.installFailed(result.errorSummary)
        }
    }

    public func removeKeyPair() {
        try? FileManager.default.removeItem(at: privateKey)
        try? FileManager.default.removeItem(at: publicKey)
    }
}
