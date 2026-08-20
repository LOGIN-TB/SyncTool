import Foundation
import Security

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "Fehler \(status)"
            return "Schlüsselbund: \(text)"
        case .invalidData:
            return "Schlüsselbund: Passwort ließ sich nicht lesen."
        }
    }
}

/// Passwoerter als Internet-Passwort, damit sie in der
/// Schluesselbundverwaltung sauber unter dem Server auftauchen.
public struct KeychainStore {
    public init() {}

    private func query(host: String, port: Int, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
        ]
    }

    public func save(password: String, host: String, port: Int, account: String) throws {
        guard let data = password.data(using: .utf8) else { throw KeychainError.invalidData }
        let base = query(host: host, port: port, account: account)

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "SyncTool – \(account)@\(host)"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func load(host: String, port: Int, account: String) throws -> String? {
        var item = query(host: host, port: port, account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return text
    }

    public func delete(host: String, port: Int, account: String) throws {
        let status = SecItemDelete(query(host: host, port: port, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
