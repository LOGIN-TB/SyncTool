import Foundation

/// Wie die App an das Ziel herankommt.
///
/// Nicht "welches Protokoll": entscheidend ist, ob am Ende ein Pfad im
/// Dateisystem steht oder eine rsync-Gegenstelle hinter ssh. Sobald ein Pfad
/// da ist, arbeitet die vorhandene Maschine unveraendert weiter.
public enum Transport: Sendable, Hashable {
    /// Der bisherige Weg. Storage Box, eigener Linux-Server, NAS mit ssh.
    case sshRsync
    /// Wird vor dem Lauf eingehaengt und danach wieder geloest.
    case mountedVolume(VolumeProtocol)
    /// Liegt schon als Pfad vor: externe Platte, Ordner eines Anbieter-Clients.
    case localFolder
    /// Aus einer neueren Fassung. Das Profil bleibt unangetastet und laeuft nie.
    case unknown(String)

    /// Rohwert fuer die Datei. `Profile` speichert diesen String und nicht das
    /// Enum selbst: ein synthetisiertes `Codable` wuerfe bei einem unbekannten
    /// Fall, und `Profile.init(from:)` ersetzte den Wurf durch die Vorbelegung.
    /// Ein Profil aus einer neueren Fassung wuerde damit stillschweigend zu
    /// einem Storage-Box-Profil und beim naechsten Speichern als solches
    /// zurueckgeschrieben.
    public var raw: String {
        switch self {
        case .sshRsync: return "sshRsync"
        case .localFolder: return "localFolder"
        case .mountedVolume(let proto): return "mount:\(proto.rawValue)"
        case .unknown(let raw): return raw
        }
    }

    /// Leer heisst: Profil aus einer Fassung vor dem Anbieterkatalog, also der
    /// einzige Weg, den es damals gab.
    public init(raw: String) {
        switch raw {
        case "", "sshRsync":
            self = .sshRsync
        case "localFolder":
            self = .localFolder
        default:
            if raw.hasPrefix("mount:"),
                let proto = VolumeProtocol(rawValue: String(raw.dropFirst("mount:".count)))
            {
                self = .mountedVolume(proto)
            } else {
                self = .unknown(raw)
            }
        }
    }

    /// Braucht rsync eine Gegenstelle hinter `-e`? Nur dann sind SSH-Sitzung,
    /// Passwort-Socket, Askpass und Host-Key ueberhaupt im Spiel.
    public var usesRemoteShell: Bool {
        if case .sshRsync = self { return true }
        return false
    }

    /// Braucht das Ziel eine Anmeldung? NFS nicht: dort entscheidet die
    /// Freigabe anhand der Adresse, ein Passwortfeld waere eine Luege.
    public var needsCredentials: Bool {
        switch self {
        case .sshRsync: return true
        case .mountedVolume(let proto): return proto.needsCredentials
        case .localFolder: return false
        case .unknown: return false
        }
    }

    /// Ein Profil, dessen Transport diese Fassung nicht kennt, wird angezeigt,
    /// aber niemals ausgefuehrt.
    public var isRunnable: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Protokolle, die macOS selbst einhaengen kann.
public enum VolumeProtocol: String, Sendable, Hashable, CaseIterable {
    case smb, nfs, webdav, afp

    public var label: String {
        switch self {
        case .smb: return "SMB"
        case .nfs: return "NFS"
        case .webdav: return "WebDAV"
        case .afp: return "AFP"
        }
    }

    /// NFS kennt keine Zugangsdaten, es entscheidet die Adresse des Rechners.
    public var needsCredentials: Bool { self != .nfs }

    /// Sollwert fuer `statfs`. Weicht der gemessene Wert ab, ist etwas anderes
    /// eingehaengt als bestellt.
    public var fsTypeName: String {
        switch self {
        case .smb: return "smbfs"
        case .nfs: return "nfs"
        case .webdav: return "webdav"
        case .afp: return "afpfs"
        }
    }
}
