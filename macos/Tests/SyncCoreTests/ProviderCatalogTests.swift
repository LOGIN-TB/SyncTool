import Foundation
import Testing

@testable import SyncCore

@Suite("Anbieterkatalog")
struct ProviderCatalogTests {

    // MARK: - Der Katalog selbst

    @Test("Jede Vorlage hat Felder, und jedes Feld eine Regel mit Meldung")
    func everyPresetIsUsable() {
        for preset in ProviderCatalog.presets(rcloneAvailable: true) {
            #expect(!preset.fields.isEmpty, "\(preset.id)")
            #expect(!preset.hint.isEmpty, "\(preset.id)")
            for field in preset.fields {
                #expect(!field.label.isEmpty, "\(preset.id)/\(field.field)")
                #expect(!field.missing.isEmpty, "\(preset.id)/\(field.field)")
            }
        }
    }

    @Test("Kennungen sind eindeutig")
    func idsAreUnique() {
        let ids = ProviderCatalog.presets(rcloneAvailable: true).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Jedes Ziel braucht den Stammordner, sonst wüsste die App nicht, was
    /// abgeglichen werden soll.
    @Test("Jede Vorlage fragt nach dem Stammordner")
    func everyPresetAsksForTheLocalRoot() {
        for preset in ProviderCatalog.presets(rcloneAvailable: true) {
            #expect(preset.fields.contains { $0.field == .localRoot }, "\(preset.id)")
        }
    }

    @Test("Jede Gruppe ist besetzt")
    func everyGroupHasEntries() {
        let groups = Set(ProviderCatalog.presets(rcloneAvailable: true).map(\.group))
        // .cloudDirect kommt erst mit dem Einhaengen dazu, steht aber schon da.
        #expect(groups.contains(.server))
        #expect(groups.contains(.nas))
        #expect(groups.contains(.cloudClient))
        #expect(groups.contains(.cloudDirect))
        #expect(groups.contains(.disk))
    }

    // MARK: - Vorlage anwenden

    @Test("Die Storage-Box-Vorlage belegt Port und Ordner vor")
    func storageBoxPrefills() throws {
        let preset = try #require(ProviderCatalog.preset(id: "hetzner-storagebox"))
        var profile = Profile(name: "Neues Ziel", localRoot: "", host: "")
        preset.apply(to: &profile)
        #expect(profile.transport == .sshRsync)
        #expect(profile.port == 23)
        #expect(profile.remotePath == "dev")
        #expect(profile.providerID == "hetzner-storagebox")
    }

    /// Der Name gehoert nicht hierher: er muss in der Liste eindeutig sein, und
    /// die kennt die Vorlage nicht.
    @Test("Die Vorlage lässt den Namen unangetastet")
    func applyDoesNotRename() throws {
        var profile = Profile(name: "Kunde Meier")
        try #require(ProviderCatalog.preset(id: "smb-share")).apply(to: &profile)
        #expect(profile.name == "Kunde Meier")
    }

    @Test("Platzhalternamen erkennt der Katalog, selbst gewählte nicht")
    func placeholderNames() {
        #expect(ProviderPreset.nameIsPlaceholder(""))
        #expect(ProviderPreset.nameIsPlaceholder("Storage Box"))
        #expect(ProviderPreset.nameIsPlaceholder("Neues Ziel"))
        #expect(ProviderPreset.nameIsPlaceholder("Neues Ziel Kopie 2"))
        #expect(!ProviderPreset.nameIsPlaceholder("Kunde Meier"))
        #expect(!ProviderPreset.nameIsPlaceholder("Storage Box Kunde"))
    }

    @Test("Die Vorlage für einen eigenen Server belegt Port 22 vor")
    func ownServerUsesPort22() throws {
        let preset = try #require(ProviderCatalog.preset(id: "ssh-server"))
        var profile = Profile()
        preset.apply(to: &profile)
        #expect(profile.port == 22)
    }

    /// Wer die Vorlage nachtraeglich wechselt, will nicht seinen Stammordner
    /// verlieren.
    @Test("Ein Vorlagenwechsel nimmt nichts weg, was der Nutzer eingetragen hat")
    func switchingPresetKeepsUserInput() throws {
        var profile = Profile(localRoot: "/Users/test/Develop", host: "box.example.org")
        let preset = try #require(ProviderCatalog.preset(id: "local-folder"))
        preset.apply(to: &profile)
        #expect(profile.localRoot == "/Users/test/Develop")
        // Der Server bleibt stehen, auch wenn dieses Ziel ihn nicht braucht:
        // ein Wechsel zurueck soll nicht bei Null anfangen.
        #expect(profile.host == "box.example.org")
    }

    /// Ein "dev" ist bei einem lokalen Ordner kein Pfad, sondern Ballast, und
    /// wuerde als "Muss mit / anfangen." gemeldet.
    @Test("Der Werks-Ordner „dev“ verschwindet bei einem lokalen Ziel")
    func factoryRemotePathIsClearedForLocalTargets() throws {
        var profile = Profile()
        #expect(profile.remotePath == "dev")
        try #require(ProviderCatalog.preset(id: "local-folder")).apply(to: &profile)
        #expect(profile.remotePath.isEmpty)
        #expect(profile.issues().contains { $0.field == .remotePath })
    }

    @Test("Ein selbst eingetragener Ordner überlebt den Vorlagenwechsel")
    func ownRemotePathSurvives() throws {
        var profile = Profile(remotePath: "projekte/kunde")
        try #require(ProviderCatalog.preset(id: "smb-share")).apply(to: &profile)
        #expect(profile.remotePath == "projekte/kunde")
    }

    /// Eine an SMB gemessene Zeitgenauigkeit sagt nichts ueber WebDAV.
    @Test("Ein Wechsel der Transportart verwirft die Messwerte")
    func switchingTransportDropsMeasurements() throws {
        var profile = Profile(transport: .mountedVolume(.smb))
        profile.probedAt = Date(timeIntervalSince1970: 1_700_000_000)
        profile.targetMarkerID = "ABCD"

        try #require(ProviderCatalog.preset(id: "nextcloud-webdav")).apply(to: &profile)
        #expect(profile.probedAt == nil)
        #expect(profile.targetMarkerID.isEmpty)
    }

    @Test("Dieselbe Transportart behält die Messwerte")
    func sameTransportKeepsMeasurements() throws {
        var profile = Profile(transport: .sshRsync)
        profile.targetMarkerID = "ABCD"
        try #require(ProviderCatalog.preset(id: "hetzner-storagebox")).apply(to: &profile)
        #expect(profile.targetMarkerID == "ABCD")
    }

    // MARK: - Vorlage zu einem Profil finden

    /// Ein Altprofil hat keine `providerID`. Ohne diesen Rueckfall stuende im
    /// Kopf des Formulars nichts.
    @Test("Ein Altprofil an einer Storage Box wird als solche erkannt")
    func legacyStorageBoxIsRecognised() {
        let profile = Profile(host: "u123456.your-storagebox.de", user: "u123456")
        #expect(ProviderCatalog.preset(for: profile)?.id == "hetzner-storagebox")
    }

    @Test("Ein Altprofil an einem eigenen Server wird als solcher erkannt")
    func legacyOwnServerIsRecognised() {
        let profile = Profile(host: "nas.fritz.box", user: "benutzer")
        #expect(ProviderCatalog.preset(for: profile)?.id == "ssh-server")
    }

    @Test("Die gespeicherte Kennung hat Vorrang vor dem Hostnamen")
    func storedIDWins() {
        var profile = Profile(host: "u1.your-storagebox.de")
        profile.providerID = "ssh-server"
        #expect(ProviderCatalog.preset(for: profile)?.id == "ssh-server")
    }

    @Test("Ein unbekannter Transport findet keine Vorlage")
    func unknownTransportHasNoPreset() {
        var profile = Profile()
        profile.transportRaw = "rclone:s3"
        #expect(ProviderCatalog.preset(for: profile) == nil)
    }

    // MARK: - Sperren statt verstecken

    @Test("Ohne rclone bleibt jede Vorlage sichtbar")
    func lockedPresetsStayVisible() {
        let without = ProviderCatalog.presets(rcloneAvailable: false)
        let with = ProviderCatalog.presets(rcloneAvailable: true)
        #expect(without.count == with.count)
        // Solange keine Vorlage rclone braucht, ist keine gesperrt. Der Test
        // haelt die Zusage fest, dass Sperren nicht heisst Verstecken.
        for preset in without where preset.unavailable != nil {
            #expect(preset.unavailable?.contains("rclone") == true, "\(preset.id)")
        }
    }
}
