import Foundation

/// Was am Ende der rsync-Zeile steht.
///
/// Rein, damit sich jede Transportart ohne Netz und ohne Einhaengung pruefen
/// laesst. rsync braucht auf beiden Seiten einen abschliessenden Schraegstrich,
/// sonst legt es den Ordner im Ziel noch einmal an.
public struct SyncEndpoints: Sendable, Equatable {
    /// Der Stammordner auf diesem Rechner.
    public let local: String
    /// Die andere Seite. Bei ssh mit `benutzer@server:` davor, sonst ein Pfad.
    public let remote: String

    public init(local: String, remote: String) {
        self.local = local
        self.remote = remote
    }

    public static func resolve(profile: Profile, mountPoint: String? = nil) -> SyncEndpoints {
        switch profile.transport {
        case .sshRsync, .unknown:
            return SyncEndpoints(local: profile.localSource, remote: profile.remoteSource)
        case .localFolder:
            return SyncEndpoints(
                local: profile.localSource, remote: withTrailingSlash(profile.remotePath)
            )
        case .mountedVolume:
            // `remotePath` zaehlt ab dem Stamm der Freigabe. Absolut waere
            // falsch: dieselbe Freigabe an einer anderen Stelle im Dateisystem
            // meinte dann einen anderen Ordner.
            let root = mountPoint ?? ""
            let joined = profile.remotePath.isEmpty
                ? root
                : (root as NSString).appendingPathComponent(profile.remotePath)
            return SyncEndpoints(local: profile.localSource, remote: withTrailingSlash(joined))
        }
    }

    static func withTrailingSlash(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed + "/"
    }
}

/// Welche rsync-Zeile eine Transportart braucht.
///
/// Die Flags stehen als Wert da und nicht als Konstante im Argumentbau, damit
/// sich eine neue Transportart hinzufuegen laesst, ohne die Zeile fuer die
/// bestehende anzufassen. Ein Golden-Test haelt `sshRsync` fest.
public struct RsyncFlavour: Sendable, Equatable {
    /// `-a` waere bequemer, zieht aber `-o`/`-g` mit. Auf einer Storage Box
    /// scheitert jedes chown, und der Lauf endet mit Fehlerstatus, obwohl die
    /// Daten stimmen.
    public let baseFlags: [String]

    /// Braucht rsync eine Gegenstelle hinter `-e`?
    public let usesRemoteShell: Bool

    public init(baseFlags: [String], usesRemoteShell: Bool) {
        self.baseFlags = baseFlags
        self.usesRemoteShell = usesRemoteShell
    }

    /// Der bisherige Weg, plus eine Zeitschranke.
    ///
    /// `--timeout=900`: Ohne sie blockiert eine haengende Verbindung den Lauf
    /// unbegrenzt, und das Statusfenster steht still, ohne zu sagen warum.
    /// `ServerAliveInterval` in `SSHCommand.options` faengt nur die tote
    /// TCP-Verbindung ab, nicht ein rsync, das bei lebender Leitung nicht
    /// weiterkommt. Der Wert ist bewusst hoch: Die Dateilistenphase kann bei
    /// dreissigtausend Eintraegen lange still sein, und ein Abbruch mitten im
    /// Lauf ist teurer als ein paar Minuten Warten.
    ///
    /// Ohne `--contimeout`: Das gilt nur fuer die Verbindung zu einem
    /// rsync-Daemon, und rsync 3.x lehnt die Zeile damit rundheraus ab, wenn
    /// ueber ssh gearbeitet wird. Nachgemessen; openrsync nimmt es an, aber
    /// eine Zeile, die nur mit einer Fassung laeuft, taugt nicht.
    public static let sshRsync = RsyncFlavour(
        baseFlags: ["-rlptz", "--timeout=900"], usesRemoteShell: true
    )

    /// Ohne `-z`: bei einem Lauf im Dateisystem komprimiert das nur die Luft
    /// und kostet Rechenzeit. Und ohne Zeitschranke: Da gibt es keine Leitung,
    /// die haengen koennte, und ein grosses Verzeichnis darf dauern.
    public static let local = RsyncFlavour(baseFlags: ["-rlpt"], usesRemoteShell: false)

    public static func forTransport(_ transport: Transport) -> RsyncFlavour {
        transport.usesRemoteShell ? .sshRsync : .local
    }
}
