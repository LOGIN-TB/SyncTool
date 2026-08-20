import Foundation

public enum ProviderGroup: String, Sendable, CaseIterable, Identifiable {
    case server
    case nas
    case cloudClient
    case cloudDirect
    case disk

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .server: return "Server und Hosting"
        case .nas: return "NAS im eigenen Netz"
        case .cloudClient: return "Cloud über den Ordner des Anbieters"
        case .cloudDirect: return "Cloud-Speicher direkt"
        case .disk: return "Platten und Ordner"
        }
    }
}

/// Eine Vorlage fuer ein Ziel.
///
/// Der Punkt ist das Vorbelegen: ein frisches Profil zeigte bisher Adresse,
/// Benutzer, Port und Ordner. Das setzt voraus, dass der Nutzer schon weiss,
/// dass sein Ziel per ssh erreichbar ist. Bei einem OneDrive-Ordner ist keines
/// der vier Felder die richtige Frage.
public struct ProviderPreset: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let group: ProviderGroup
    public let transport: Transport
    /// SF-Symbol.
    public let icon: String
    /// Ein Satz in Alltagssprache: was das Ziel ist und was der Nutzer dafuer
    /// braucht.
    public let hint: String
    /// Was an diesem Ziel nicht geht. Steht vor dem Ausfuellen da und nicht als
    /// Fehlermeldung danach.
    public let limits: [String]
    /// Braucht dieses Ziel ein Werkzeug, das die App noch nicht mitbringt?
    /// Nicht `nil` heisst: im Katalog sichtbar, aber gesperrt, mit diesem Satz
    /// als Begruendung. Sperren statt verstecken, damit der Nutzer sieht, dass
    /// es geht, und warum es gerade nicht geht.
    public let unavailable: String?
    /// Alles, was sich vorbelegen laesst.
    public let defaults: Defaults
    /// Platzhalter, die diese Vorlage anders setzt als die Transportart.
    ///
    /// Die Transportart kennt nur generische Beispiele, weil sie fuer alle ihre
    /// Anbieter gilt. Ein `u123456.your-storagebox.de` ist aber genau die Form,
    /// die ein Storage-Box-Nutzer braucht, und nur der.
    public let prompts: [ProfileField: String]

    public init(
        id: String,
        name: String,
        group: ProviderGroup,
        transport: Transport,
        icon: String,
        hint: String,
        limits: [String],
        unavailable: String?,
        defaults: Defaults,
        prompts: [ProfileField: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.transport = transport
        self.icon = icon
        self.hint = hint
        self.limits = limits
        self.unavailable = unavailable
        self.defaults = defaults
        self.prompts = prompts
    }

    /// Vorbelegung als Wert statt als Funktion, damit `ProviderPreset`
    /// vergleichbar bleibt und sich der Katalog testen laesst.
    public struct Defaults: Sendable, Hashable {
        public var port: Int?
        public var remotePath: String?
        public var authMode: AuthMode?
        public var host: String?

        public init(
            port: Int? = nil, remotePath: String? = nil, authMode: AuthMode? = nil,
            host: String? = nil
        ) {
            self.port = port
            self.remotePath = remotePath
            self.authMode = authMode
            self.host = host
        }
    }

    public var fields: [FieldDescriptor] {
        TransportFields.descriptors(for: transport).map { descriptor in
            guard let prompt = prompts[descriptor.field] else { return descriptor }
            return descriptor.with(prompt: prompt)
        }
    }

    /// Setzt die Vorlage auf ein Profil.
    ///
    /// Nur vorbelegen, nichts wegnehmen, was der Nutzer schon eingetragen hat:
    /// wer die Vorlage nachtraeglich wechselt, will nicht seinen Stammordner
    /// verlieren.
    /// Der Name bleibt hier unangetastet: er muss in der Liste eindeutig sein,
    /// und die Liste kennt diese Ebene nicht. Darum kuemmert sich `AppState`.
    public func apply(to profile: inout Profile) {
        let previous = profile.transport
        profile.providerID = id
        profile.transportRaw = transport.raw
        if let port = defaults.port { profile.port = port }
        if let authMode = defaults.authMode { profile.authMode = authMode }
        if let host = defaults.host { profile.host = host }
        // Ein "dev" aus der Werksvorbelegung ist bei einem lokalen Ordner kein
        // Pfad, sondern Ballast. Es gilt nur so lange, wie der Nutzer es nicht
        // selbst angefasst hat.
        if profile.remotePath.isEmpty || profile.remotePath == Profile().remotePath {
            profile.remotePath = defaults.remotePath ?? ""
        }
        // Wechselt die Transportart, sind alle Messwerte hinfaellig: eine an
        // SMB gemessene Zeitgenauigkeit sagt nichts ueber WebDAV.
        if previous != transport {
            profile.probedAt = nil
            profile.targetMarkerID = ""
        }
    }
}

extension ProviderPreset {
    /// Traegt der Name noch keine Aussage? Dann darf die Vorlage ihn setzen.
    ///
    /// "Neues Ziel" und "Storage Box" sind Platzhalter aus der Zeit, in der es
    /// nur ein Ziel gab. Ein selbst gewaehlter Name bleibt stehen.
    public static func nameIsPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed == Profile().name { return true }
        return trimmed == "Neues Ziel" || trimmed.hasPrefix("Neues Ziel ")
    }
}

public enum ProviderCatalog {
    public static func presets(rcloneAvailable: Bool = false) -> [ProviderPreset] {
        all.map { preset in
            guard preset.needsRclone, !rcloneAvailable else { return preset.stripped }
            return preset.locked(
                "Dieses Ziel braucht rclone. Mit `brew install rclone` nachinstallieren, "
                    + "dann steht es hier zur Verfügung."
            )
        }
    }

    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.preset.id == id }?.preset
    }

    /// Vorlage zu einem Profil. Ohne `providerID` wird sie aus dem Transport
    /// erraten, damit auch Altprofile eine Beschriftung haben.
    public static func preset(for profile: Profile) -> ProviderPreset? {
        if let found = preset(id: profile.providerID) { return found }
        if case .sshRsync = profile.transport {
            return profile.host.contains("your-storagebox.de")
                ? preset(id: "hetzner-storagebox") : preset(id: "ssh-server")
        }
        return all.first { $0.preset.transport == profile.transport }?.preset
    }

    // MARK: - Der Katalog

    /// `needsRclone` steht neben der Vorlage und nicht darin: ob ein Ziel
    /// verfuegbar ist, haengt am Rechner und nicht an der Vorlage.
    struct Entry: Sendable {
        let preset: ProviderPreset
        let needsRclone: Bool

        var stripped: ProviderPreset { preset }
        func locked(_ reason: String) -> ProviderPreset { preset.with(unavailable: reason) }
    }

    static let all: [Entry] = [
        Entry(
            preset: ProviderPreset(
                id: "hetzner-storagebox",
                name: "Hetzner Storage Box",
                group: .server,
                transport: .sshRsync,
                icon: "shippingbox",
                hint: "Die Zugangsdaten stehen in der Hetzner-Konsole bei der Storage Box. "
                    + "Storage Boxen hören auf Port 23.",
                limits: [],
                unavailable: nil,
                defaults: .init(port: 23, remotePath: "dev", authMode: .password),
                prompts: [
                    .host: "u123456.your-storagebox.de",
                    .user: "u123456",
                    .remotePath: "dev",
                ]
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "ssh-server",
                name: "Eigener Server oder NAS über SSH",
                group: .server,
                transport: .sshRsync,
                icon: "terminal",
                hint: "Für jeden Rechner, auf dem sich rsync über SSH erreichen lässt: "
                    + "Hetzner Cloud, netcup, IONOS, Strato, Contabo, Synology und QNAP mit "
                    + "eingeschaltetem SSH.",
                limits: [
                    "Auf der Gegenseite muss rsync liegen. Reines SFTP ohne Shell genügt nicht."
                ],
                unavailable: nil,
                defaults: .init(port: 22, remotePath: "dev", authMode: .password)
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "smb-share",
                name: "SMB-Freigabe",
                group: .nas,
                transport: .mountedVolume(.smb),
                icon: "externaldrive.connected.to.line.below",
                hint: "Jedes NAS, ein USB-Laufwerk am Router, eine Windows-Freigabe. "
                    + "Auch die Hetzner Storage Box spricht SMB.",
                limits: [
                    "Wird vor dem Lauf eingehängt und danach wieder gelöst.",
                    "Rechte und Zeitstempel hängen am Server. „Verbindung testen“ misst nach.",
                ],
                unavailable: nil,
                defaults: .init(port: 445, remotePath: "")
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "nfs-export",
                name: "NFS-Export",
                group: .nas,
                transport: .mountedVolume(.nfs),
                icon: "network",
                hint: "Für NAS-Geräte und Linux-Rechner im eigenen Netz. NFS fragt nicht nach "
                    + "einem Passwort, es entscheidet die Adresse dieses Rechners.",
                limits: [
                    "Der Export muss diesen Rechner zulassen.",
                    "Der Kernel normalisiert keine Umlaute in Dateinamen.",
                ],
                unavailable: nil,
                defaults: .init(remotePath: "")
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "nextcloud-webdav",
                name: "Nextcloud über WebDAV",
                group: .cloudDirect,
                transport: .mountedVolume(.webdav),
                icon: "cloud",
                hint: "Auch für Hetzner Storage Share und IONOS. Die Adresse lautet "
                    + "https://SERVER/remote.php/dav/files/BENUTZER. Mit aktivierter "
                    + "Zwei-Faktor-Anmeldung braucht es ein App-Passwort.",
                limits: [
                    "WebDAV hält keine Symlinks und oft keine Änderungszeiten.",
                    "Der Ordner des Nextcloud-Clients ist der bessere Weg, wenn er in Frage "
                        + "kommt: dort stimmen Zeitstempel und Symlinks.",
                ],
                unavailable: nil,
                defaults: .init(remotePath: "")
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "magentacloud-webdav",
                name: "Telekom MagentaCloud",
                group: .cloudDirect,
                transport: .mountedVolume(.webdav),
                icon: "cloud",
                hint: "Die MagentaCloud läuft auf Nextcloud. Die Adresse lautet "
                    + "https://magentacloud.de/remote.php/dav/files/ANID, und der Zugang "
                    + "braucht ein App-Passwort aus den Kontoeinstellungen.",
                limits: ["WebDAV hält keine Symlinks und oft keine Änderungszeiten."],
                unavailable: nil,
                defaults: .init(remotePath: "")
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "hidrive-webdav",
                name: "Strato HiDrive über WebDAV",
                group: .cloudDirect,
                transport: .mountedVolume(.webdav),
                icon: "cloud",
                hint: "Die Adresse lautet https://webdav.hidrive.strato.com/users/BENUTZER. "
                    + "Auf manchen Tarifen bietet HiDrive zusätzlich rsync über SSH an, und "
                    + "das ist der deutlich bessere Weg.",
                limits: ["WebDAV hält keine Symlinks und oft keine Änderungszeiten."],
                unavailable: nil,
                defaults: .init(remotePath: "")
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "onedrive-folder",
                name: "OneDrive über den Client",
                group: .cloudClient,
                transport: .localFolder,
                icon: "arrow.trianglehead.2.clockwise.rotate.90.icloud",
                hint: "Der OneDrive-Client legt seinen Ordner unter "
                    + "~/Library/CloudStorage ab. SyncTool gleicht dann mit diesem Ordner "
                    + "ab, und der Client bringt die Dateien in die Cloud.",
                limits: [
                    "Nur-online-Dateien werden beim Lesen heruntergeladen. SyncTool prüft "
                        + "das vorher und fragt nach."
                ],
                unavailable: nil,
                defaults: .init()
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "googledrive-folder",
                name: "Google Drive über den Client",
                group: .cloudClient,
                transport: .localFolder,
                icon: "arrow.trianglehead.2.clockwise.rotate.90.icloud",
                hint: "Google Drive für den Desktop legt seinen Ordner unter "
                    + "~/Library/CloudStorage ab.",
                limits: [
                    "Nur-online-Dateien werden beim Lesen heruntergeladen. SyncTool prüft "
                        + "das vorher und fragt nach."
                ],
                unavailable: nil,
                defaults: .init()
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "nextcloud-folder",
                name: "Nextcloud über den Client",
                group: .cloudClient,
                transport: .localFolder,
                icon: "arrow.trianglehead.2.clockwise.rotate.90.icloud",
                hint: "Der beste Weg für Nextcloud und die MagentaCloud: der Client hält den "
                    + "Ordner auf der Platte, damit stimmen Zeitstempel und Symlinks.",
                limits: [
                    "In den Client-Einstellungen dürfen die „virtuellen Dateien“ nicht "
                        + "eingeschaltet sein, sonst gilt dasselbe wie für Nur-online-Dateien."
                ],
                unavailable: nil,
                defaults: .init()
            ),
            needsRclone: false
        ),
        Entry(
            preset: ProviderPreset(
                id: "local-folder",
                name: "Externe Platte oder Ordner",
                group: .disk,
                transport: .localFolder,
                icon: "externaldrive",
                hint: "Eine zweite Platte, ein Time-Machine-Laufwerk, ein beliebiger Ordner "
                    + "auf diesem Rechner.",
                limits: [],
                unavailable: nil,
                defaults: .init()
            ),
            needsRclone: false
        ),
    ]
}

extension ProviderPreset {
    func with(unavailable: String?) -> ProviderPreset {
        ProviderPreset(
            id: id, name: name, group: group, transport: transport, icon: icon, hint: hint,
            limits: limits, unavailable: unavailable, defaults: defaults, prompts: prompts
        )
    }
}
