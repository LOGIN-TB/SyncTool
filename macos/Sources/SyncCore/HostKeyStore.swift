import Foundation

public struct HostKeyCandidate: Sendable, Identifiable {
    public let id = UUID()
    /// Zeile im known_hosts-Format.
    public let line: String
    public let keyType: String
    /// SHA256-Fingerprint, so wie ssh ihn anzeigt.
    public let fingerprint: String
}

public enum HostKeyError: LocalizedError {
    case scanFailed(String)
    case noKeys(String)

    public var errorDescription: String? {
        switch self {
        case .scanFailed(let detail):
            return "Host-Key ließ sich nicht abrufen: \(detail)"
        case .noKeys(let host):
            return "\(host) hat keinen Host-Key geliefert. Erreichbar? Richtiger Port?"
        }
    }
}

/// Eigene known_hosts, damit die App die Vertrauensentscheidung selbst
/// anzeigen kann und nicht in ~/.ssh/known_hosts schreibt.
public struct HostKeyStore {
    public let file: URL

    public init(file: URL = AppPaths.knownHostsFile) {
        self.file = file
    }

    public func isKnown(host: String, port: Int) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let needle = port == 22 ? host : "[\(host)]:\(port)"
        return content.split(separator: "\n").contains { line in
            guard !line.hasPrefix("#") else { return false }
            guard let hosts = line.split(separator: " ").first else { return false }
            return hosts.split(separator: ",").contains { $0 == needle }
        }
    }

    /// Holt die angebotenen Host-Keys, ohne etwas zu speichern.
    public func fetchCandidates(host: String, port: Int) async throws -> [HostKeyCandidate] {
        let scan = try await CommandRunner.run(
            executable: SSHCommand.keyscanPath,
            arguments: ["-p", String(port), "-T", "10", host],
            timeout: 30
        )
        let lines = scan.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else {
            if !scan.succeeded { throw HostKeyError.scanFailed(scan.errorSummary) }
            throw HostKeyError.noKeys(host)
        }

        var candidates: [HostKeyCandidate] = []
        for line in lines {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 3 else { continue }
            let fingerprint = try await fingerprintFor(line: line) ?? "unbekannt"
            candidates.append(
                HostKeyCandidate(line: line, keyType: parts[1], fingerprint: fingerprint)
            )
        }
        // ed25519 zuerst, das ist der Key, den Nutzer typischerweise vergleichen.
        return candidates.sorted { lhs, rhs in
            (lhs.keyType.contains("ed25519") ? 0 : 1) < (rhs.keyType.contains("ed25519") ? 0 : 1)
        }
    }

    private func fingerprintFor(line: String) async throws -> String? {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synctool-hostkey-\(UUID().uuidString)")
        try line.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = try await CommandRunner.run(
            executable: SSHCommand.keygenPath,
            arguments: ["-l", "-f", temp.path],
            timeout: 15
        )
        guard result.succeeded else { return nil }
        // Format: "256 SHA256:… host (ED25519)"
        let fields = result.standardOutput.split(separator: " ").map(String.init)
        return fields.first(where: { $0.hasPrefix("SHA256:") })
    }

    public func trust(_ candidate: HostKeyCandidate) throws {
        try AppPaths.ensureSupportDirectory()
        let fm = FileManager.default

        // Mehrfaches Bestätigen soll die Datei nicht mit Dubletten füllen.
        if let existing = try? String(contentsOf: file, encoding: .utf8),
            existing.split(separator: "\n").contains(where: { $0 == candidate.line })
        {
            return
        }

        if !fm.fileExists(atPath: file.path) {
            fm.createFile(
                atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((candidate.line + "\n").utf8))
    }

    /// Entfernt alle Eintraege zu einem Ziel, etwa nach einem Serverwechsel.
    public func forget(host: String, port: Int) throws {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let needle = port == 22 ? host : "[\(host)]:\(port)"
        let kept = content.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let hosts = line.split(separator: " ").first else { return true }
            return !hosts.split(separator: ",").contains { $0 == needle }
        }
        try kept.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
