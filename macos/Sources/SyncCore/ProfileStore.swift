import Foundation

/// Liest und schreibt die Profilliste als JSON. Passwoerter stehen dort nie drin.
public final class ProfileStore {
    private let url: URL

    public init(url: URL = AppPaths.profilesFile) {
        self.url = url
    }

    /// Ergebnis des Ladens. Ein Lesefehler ist etwas anderes als eine leere
    /// Liste, und der Unterschied entscheidet, ob gespeichert werden darf.
    public enum LoadResult: Sendable {
        /// Keine Datei da. Erster Start, ein neues Profil ist richtig.
        case empty
        case profiles([Profile])
        /// Datei da, aber unlesbar. Auf keinen Fall darueberschreiben.
        case unreadable(String)
    }

    public func loadResult() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            return .profiles(try JSONDecoder().decode([Profile].self, from: data))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func load() -> [Profile] {
        if case .profiles(let profiles) = loadResult() { return profiles }
        return []
    }

    public func save(_ profiles: [Profile]) throws {
        try AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}
