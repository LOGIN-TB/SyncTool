import Foundation
import Testing

@testable import SyncCore

@Suite("Profil lesen und schreiben")
struct ProfileTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    /// Der synthetisierte Decodable wendet Vorbelegungen nicht an. Ohne den
    /// eigenen Decoder scheiterte das Lesen an jedem neuen Feld, und der naechste
    /// Speichervorgang haette die echten Zugangsdaten ueberschrieben.
    @Test("Ein Profil aus einer Version ohne die Backup-Felder lässt sich weiter lesen")
    func oldProfileStillDecodes() throws {
        let profiles = try JSONDecoder().decode([Profile].self, from: try fixture("profiles-v1"))
        let profile = try #require(profiles.first)

        #expect(profile.host == "u123456-sub1.your-storagebox.de")
        #expect(profile.user == "u123456-sub1")
        #expect(profile.remotePath == "dev")
        #expect(profile.localRoot == "/Users/test/Develop")
        #expect(profile.port == 23)
        #expect(profile.maxDelete == 1000)
        #expect(profile.deleteAllowed)
        #expect(profile.useChecksum)
        #expect(profile.excludes == [".DS_Store", "node_modules/"])
        #expect(profile.id.uuidString == "21D48F9B-6E1B-44CA-9545-464463FB1579")
    }

    @Test("Fehlende Felder bekommen ihre Vorgabewerte")
    func missingFieldsFallBack() throws {
        let profiles = try JSONDecoder().decode([Profile].self, from: try fixture("profiles-v1"))
        #expect(try #require(profiles.first).backupDestination == "")
    }

    /// Die Absturzsicherung darf ein Altprofil nicht sperren: ohne Kennung
    /// wird keine geprueft, und `probedAt` muss `nil` bleiben statt
    /// `.some(nil)` zu werden.
    @Test("Ein Altprofil hat keine Kennung und keine Messung")
    func oldProfileHasNoMarker() throws {
        let profile = try #require(
            try JSONDecoder().decode([Profile].self, from: try fixture("profiles-v1")).first
        )
        #expect(profile.targetMarkerID.isEmpty)
        #expect(profile.probedAt == nil)
    }

    /// Drei Profile in einer Datei: eines von vor dem Anbieterkatalog, eines
    /// mit lokalem Ordner, eines aus einer Fassung, die diese hier nicht kennt.
    /// Keines darf das Lesen der anderen zunichte machen.
    @Test("Eine gemischte Profildatei liest alle drei Arten")
    func mixedProfilesDecode() throws {
        let profiles = try JSONDecoder().decode(
            [Profile].self, from: try fixture("profiles-v2-mixed")
        )
        #expect(profiles.count == 3)

        // Ohne transportRaw: der Weg, den es damals als einzigen gab.
        #expect(profiles[0].transport == .sshRsync)
        #expect(profiles[0].isRunnable)
        #expect(profiles[0].providerID.isEmpty)

        #expect(profiles[1].transport == .localFolder)
        #expect(profiles[1].providerID == "onedrive-folder")
        #expect(profiles[1].isRunnable)
        // Host, Benutzer und Port stehen leer beziehungsweise auf der Vorgabe.
        // Geprueft werden sie nicht, weil dieses Ziel sie nicht braucht.
        #expect(profiles[1].issues().isEmpty)

        // Aus einer neueren Fassung: bleibt lesbar, laeuft aber nie.
        #expect(profiles[2].transport == .unknown("rclone:s3"))
        #expect(!profiles[2].isRunnable)
    }

    /// Der eigentliche Grund fuer den Rohwert: ein Profil, das diese Fassung
    /// nicht versteht, muss die Datei unveraendert wieder verlassen.
    @Test("Ein unbekannter Transport übersteht das Speichern unverändert")
    func unknownTransportSurvivesSaving() throws {
        let profiles = try JSONDecoder().decode(
            [Profile].self, from: try fixture("profiles-v2-mixed")
        )
        let data = try JSONEncoder().encode(profiles)
        let back = try JSONDecoder().decode([Profile].self, from: data)
        #expect(back[2].transportRaw == "rclone:s3")
        #expect(back[2].transport == .unknown("rclone:s3"))
    }

    @Test("Kennung und Messzeitpunkt überstehen den Umweg über die Datei")
    func markerRoundTrips() throws {
        let stamp = Date(timeIntervalSince1970: 1_770_000_000)
        var profile = Profile(localRoot: "/tmp", host: "example.org", user: "u1")
        profile.targetMarkerID = "7F3A"
        profile.probedAt = stamp

        let data = try JSONEncoder().encode([profile])
        let back = try #require(try JSONDecoder().decode([Profile].self, from: data).first)
        #expect(back.targetMarkerID == "7F3A")
        #expect(back.probedAt == stamp)
    }

    @Test("Ein leeres Objekt ergibt ein brauchbares Profil statt eines Fehlers")
    func emptyObjectDecodes() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data("{}".utf8))
        #expect(profile.name == Profile().name)
        #expect(profile.port == 23)
        #expect(profile.excludes == Profile.defaultExcludes)
    }

    @Test("Sichern und Laden übersteht den Umweg über die Datei")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProfileStore(url: directory.appendingPathComponent("profiles.json"))
        var profile = Profile(localRoot: "/tmp", host: "example.org", user: "u1")
        profile.backupDestination = "/Volumes/Backup"
        try store.save([profile])

        let loaded = try #require(store.load().first)
        #expect(loaded.backupDestination == "/Volumes/Backup")
        #expect(loaded.id == profile.id)
    }

    /// Sonst legt die App ein leeres Profil an und ueberschreibt beim naechsten
    /// Schliessen der Einstellungen die noch vorhandenen Zugangsdaten.
    @Test("Eine kaputte Datei meldet einen Fehler, statt keine Profile zu melden")
    func brokenFileIsNotAnEmptyList() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("profiles.json")
        try Data("das ist kein JSON".utf8).write(to: url)

        let store = ProfileStore(url: url)
        guard case .unreadable = store.loadResult() else {
            Issue.record("Eine kaputte Datei muss als unlesbar gemeldet werden.")
            return
        }
    }

    @Test("Eine fehlende Datei ist kein Fehler, sondern der erste Start")
    func missingFileIsNotAnError() {
        let store = ProfileStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("gibt-es-nicht-\(UUID().uuidString).json")
        )
        guard case .empty = store.loadResult() else {
            Issue.record("Eine fehlende Datei muss als leer gelten.")
            return
        }
    }

    /// Frueher raeumte das Loeschen nur inventory-<id>.json weg; der Eintrag in
    /// state.json blieb fuer immer stehen.
    @Test("Der letzte Abgleich eines gelöschten Profils verschwindet aus state.json")
    func forgettingRemovesTheTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SyncStateStore(url: directory.appendingPathComponent("state.json"))
        let weg = Profile(localRoot: "/tmp", host: "a", user: "u")
        let bleibt = Profile(localRoot: "/tmp", host: "b", user: "u")
        store.recordSync(for: weg)
        store.recordSync(for: bleibt)
        #expect(store.load().lastSync(for: weg) != nil)

        store.forget(weg.id)
        #expect(store.load().lastSync(for: weg) == nil)
        #expect(store.load().lastSync(for: bleibt) != nil)
    }

    @Test("Eine unbekannte Kennung zu vergessen ändert nichts")
    func forgettingUnknownIsHarmless() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synctool-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SyncStateStore(url: directory.appendingPathComponent("state.json"))
        let bleibt = Profile(localRoot: "/tmp", host: "b", user: "u")
        store.recordSync(for: bleibt)
        store.forget(UUID())
        #expect(store.load().lastSync(for: bleibt) != nil)
    }
}
