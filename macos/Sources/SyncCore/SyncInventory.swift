import Foundation

/// Der Dateibestand, den beide Seiten beim letzten Abgleich gemeinsam hatten.
///
/// Ohne dieses Gedaechtnis sieht eine lokal geloeschte Datei genauso aus wie
/// eine neue Datei auf dem Server: beide liegen nur auf einer Seite.
public struct SyncInventory: Codable, Sendable {
    /// Aktuelles Format. Frueher stand hier der komplette lokale Baum, auch
    /// Dateien, die nie auf dem Server waren. Solche Dateien galten beim
    /// naechsten Pruefen als "auf dem Server geloescht" und verschwanden bei
    /// einem Herunterladen mit Loeschen. Deshalb die Kennzeichnung.
    public static let currentSchema = 2

    public var paths: Set<String>
    public var capturedAt: Date
    /// `nil` heisst: aus einer Version, die den lokalen Vollscan geschrieben hat.
    public var schema: Int?

    public var isTrustworthy: Bool { schema == Self.currentSchema }

    public init(paths: Set<String>, capturedAt: Date = Date(), schema: Int? = currentSchema) {
        self.paths = paths
        self.capturedAt = capturedAt
        self.schema = schema
    }

    /// Der gemeinsame Bestand nach einer Uebertragung.
    ///
    /// Abgeleitet aus den beiden Bestaenden, die die Pruefung vorher gemessen
    /// hat. Reine Mengenarithmetik, damit sie sich ohne Dateisystem pruefen laesst.
    public static func afterTransfer(
        previous: Set<String>,
        remote: Set<String>,
        local: Set<String>,
        direction: SyncDirection,
        includeDeletes: Bool,
        succeeded: Bool
    ) -> Set<String> {
        // Kein sauberer Durchlauf: Was vorher schon auf beiden Seiten lag, liegt
        // dort weiterhin. Alles daruber hinaus waere geraten.
        guard succeeded else { return remote.intersection(local) }

        switch (direction, includeDeletes) {
        case (.pull, true):
            // Danach spiegelt die lokale Seite den Server.
            return remote
        case (.pull, false):
            // Was auf dem Server geloescht wurde, liegt hier noch. Faellt es aus
            // dem Bestand, gilt es beim naechsten Pruefen als Neuzugang von hier.
            return remote.union(previous.intersection(local))
        case (.push, true):
            return local
        case (.push, false):
            return local.union(previous.intersection(remote))
        }
    }

    /// Macht ein Inventar aus der alten Version wieder brauchbar.
    ///
    /// Was darin steht, aber nicht auf dem Server liegt, war nie gemeinsamer
    /// Bestand. Genau diese Eintraege haben Dateien verschluckt.
    ///
    /// Der Preis ist bekannt und die harmlose Richtung: Ein Pfad, der wirklich
    /// auf dem Server geloescht wurde und hier noch liegt, faellt mit heraus und
    /// gilt einmalig als Upload statt als Loeschung.
    public static func healed(legacy: Set<String>, remote: Set<String>) -> Set<String> {
        legacy.intersection(remote)
    }
}

public final class InventoryStore {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
    }

    private func url(for profile: Profile) -> URL {
        directory.appendingPathComponent("inventory-\(profile.id.uuidString).json")
    }

    public func load(for profile: Profile) -> SyncInventory? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let data = try? Data(contentsOf: url(for: profile)),
            let inventory = try? JSONDecoder().decode(SyncInventory.self, from: data)
        else { return nil }
        return inventory
    }

    public func save(_ inventory: SyncInventory, for profile: Profile) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(inventory) else { return }
        try? data.write(to: url(for: profile), options: .atomic)
    }

    public func remove(for profile: Profile) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: profile))
    }

    /// Schreibt den gemeinsamen Bestand nach einer Uebertragung fort.
    public func record(
        for profile: Profile, commonPaths: Set<String>, at date: Date = Date()
    ) {
        save(SyncInventory(paths: commonPaths, capturedAt: date), for: profile)
    }

    /// Die Pfade, die beim Pruefen ueber "geloescht oder neu" entscheiden.
    ///
    /// `nil` heisst: noch nichts Belastbares da, dann greift ersatzweise der
    /// Zeitstempelvergleich gegen den letzten Abgleich. Ein Inventar aus der
    /// alten Version wird dabei an der Fernseite geradegezogen und zurueckgeschrieben.
    public func trustedPaths(for profile: Profile, remotePaths: Set<String>) -> Set<String>? {
        guard let inventory = load(for: profile) else { return nil }
        if inventory.isTrustworthy { return inventory.paths }
        let healed = SyncInventory.healed(legacy: inventory.paths, remote: remotePaths)
        save(SyncInventory(paths: healed, capturedAt: inventory.capturedAt), for: profile)
        return healed
    }
}
