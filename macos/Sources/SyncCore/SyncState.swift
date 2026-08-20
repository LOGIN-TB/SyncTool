import Foundation

/// Merkt sich pro Profil, wann zuletzt erfolgreich uebertragen wurde.
///
/// Das reicht nicht fuer echte Zwei-Wege-Sync, aber genau dafuer wird es auch
/// nicht benutzt: es beantwortet nur die Frage, ob eine Datei seit dem letzten
/// Abgleich auf beiden Seiten angefasst wurde.
public struct SyncState: Codable, Sendable {
    public var lastSyncByProfile: [String: Date]

    public init(lastSyncByProfile: [String: Date] = [:]) {
        self.lastSyncByProfile = lastSyncByProfile
    }

    public func lastSync(for profile: Profile) -> Date? {
        lastSyncByProfile[profile.id.uuidString]
    }
}

public final class SyncStateStore {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("state.json")) {
        self.url = url
    }

    public func load() -> SyncState {
        lock.lock()
        defer { lock.unlock() }
        guard
            let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    /// Raeumt den Eintrag eines geloeschten Profils weg.
    ///
    /// Ohne das wuechse state.json mit jeder Loeschung um eine Leiche: die
    /// Kennung wird nie wieder vergeben, der Zeitstempel bliebe fuer immer stehen.
    public func forget(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
            var state = try? JSONDecoder().decode(SyncState.self, from: data),
            state.lastSyncByProfile.removeValue(forKey: id.uuidString) != nil
        else { return }
        if let encoded = try? JSONEncoder().encode(state) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    public func recordSync(for profile: Profile, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state: SyncState
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(SyncState.self, from: data)
        {
            state = decoded
        } else {
            state = SyncState()
        }
        state.lastSyncByProfile[profile.id.uuidString] = date
        _ = try? AppPaths.ensureSupportDirectory()
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
