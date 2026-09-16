import Foundation

/// Liest und schreibt kleine Dateien im Zielordner, egal wie er erreicht wird.
///
/// Drei Dinge brauchen das, und alle drei aus demselben Grund: Sie beantworten
/// Fragen, die nur die Gegenstelle beantworten kann, weil sie fuer alle Rechner
/// dieselbe ist. Die Kennung des Ziels, die Sperre gegen gleichzeitige Laeufe
/// und der gemeinsame Stand.
///
/// Es geht dabei um Kilobyte, nicht um Datenbestaende. Ein eigener rsync-Lauf
/// je Datei waere dafuer die falsche Groessenordnung, und ueber ssh ist `cat`
/// ohnehin der kuerzere Weg.
/// Was der Motor von einem Zielordner braucht.
///
/// Als Protokoll, damit die Tests eine Attrappe einsetzen koennen. Ohne das
/// waere jeder Test, der eine Uebertragung fahren laesst, an echte ssh-Aufrufe
/// gebunden und liefe fuenfzehn Sekunden je Versuch in den Verbindungsablauf.
public protocol RemoteFiles {
    func read(_ name: String) async -> Data?
    func list(_ name: String) async -> [String]
    func write(_ data: Data, to name: String) async throws
    func remove(_ names: [String], under directory: String) async throws
    func claim(_ name: String) async -> RemoteClaim
}

public enum RemoteClaim: Sendable {
    /// Dieser Lauf hat sie und muss sie wieder loesen.
    case claimed
    /// Ein anderer Lauf hat sie.
    case taken
    /// Nicht nachzusehen. Die Gegenstelle antwortet nicht.
    ///
    /// Bewusst unterschieden von `taken`: Wer nicht nachsehen kann, weiss
    /// nicht, ob jemand laeuft, und darf daraus kein Nein machen. Geht die
    /// Verbindung wirklich nicht, scheitert gleich darauf der Lauf selbst, und
    /// zwar mit einer Meldung, die den Grund nennt. Eine Sperre, die bei jeder
    /// Stoerung blockiert, waere genau die Art Huerde, die Leute dazu bringt,
    /// sie abzuschalten.
    case unavailable
}

/// Bewusst nicht `Sendable`: `SSHSession` ist es nicht, und das soll sie auch
/// nicht sein. Ein Store lebt innerhalb eines Laufs und wandert nirgendwohin.
public struct RemoteStore: RemoteFiles {
    public enum Backend {
        /// Ueber ssh, mit dem Zielpfad auf der Gegenseite.
        case session(SSHSession, root: String)
        /// Ein Ordner im Dateisystem: eingehaengte Freigabe, externe Platte.
        case fileSystem(URL)
    }

    private let backend: Backend
    /// Kurz gehalten: Diese Aufrufe tauschen Kilobyte. Haengt die Leitung,
    /// soll der Lauf das schnell merken und nicht in der Vorbereitung stehen.
    private let timeout: TimeInterval

    public init(backend: Backend, timeout: TimeInterval = 20) {
        self.backend = backend
        self.timeout = timeout
    }

    /// `nil`, wenn der Transport keinen erreichbaren Ordner hat.
    public static func make(
        profile: Profile, session: SSHSession?, endpoints: SyncEndpoints
    ) -> RemoteFiles? {
        if let session {
            let root = profile.remotePath.hasSuffix("/")
                ? String(profile.remotePath.dropLast()) : profile.remotePath
            return RemoteStore(backend: .session(session, root: root))
        }
        guard !endpoints.remote.isEmpty else { return nil }
        return RemoteStore(backend: .fileSystem(URL(fileURLWithPath: endpoints.remote)))
    }

    // MARK: - Lesen

    /// `nil` heisst: gibt es nicht. Ein Lesefehler ist kein Wurf, sondern
    /// dasselbe wie "nicht da": Jeder Aufrufer hier kann ohne die Datei weiter,
    /// und ein Lauf soll nicht daran scheitern, dass eine Nebensache fehlt.
    public func read(_ name: String) async -> Data? {
        switch backend {
        case .session(let session, let root):
            // `2>/dev/null || true`: Fehlt die Datei, ist das kein Fehler.
            // Ohne das endete `cat` auf Status 1 und `runRemote` wuerfe.
            let result = try? await session.runRemote(
                "cat \(SSHCommand.shellQuote(path(root, name))) 2>/dev/null || true",
                timeout: timeout
            )
            guard let text = result?.standardOutput, !text.isEmpty else { return nil }
            return Data(text.utf8)
        case .fileSystem(let root):
            return try? Data(contentsOf: root.appendingPathComponent(name))
        }
    }

    public func list(_ name: String) async -> [String] {
        switch backend {
        case .session(let session, let root):
            let result = try? await session.runRemote(
                "ls -1 \(SSHCommand.shellQuote(path(root, name))) 2>/dev/null || true",
                timeout: timeout
            )
            return (result?.standardOutput ?? "")
                .split(separator: "\n").map(String.init)
        case .fileSystem(let root):
            return (try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(name).path
            )) ?? []
        }
    }

    // MARK: - Schreiben

    /// Der Inhalt geht ueber stdin, nicht als Teil der Kommandozeile.
    ///
    /// Sonst muesste JSON durch die Shell, und jedes Anfuehrungszeichen darin
    /// waere eine Gelegenheit, etwas falsch zu machen. `cat > datei` nimmt
    /// alles woertlich.
    public func write(_ data: Data, to name: String) async throws {
        let text = String(decoding: data, as: UTF8.self)
        switch backend {
        case .session(let session, let root):
            let target = path(root, name)
            let directory = (target as NSString).deletingLastPathComponent
            _ = try await session.runRemote(
                "mkdir -p \(SSHCommand.shellQuote(directory)) && "
                    + "cat > \(SSHCommand.shellQuote(target))",
                standardInput: text,
                timeout: timeout
            )
        case .fileSystem(let root):
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    public func remove(_ names: [String], under directory: String) async throws {
        guard !names.isEmpty else { return }
        switch backend {
        case .session(let session, let root):
            let base = path(root, directory)
            let quoted = names.map {
                SSHCommand.shellQuote((base as NSString).appendingPathComponent($0))
            }
            _ = try await session.runRemote(
                "rm -rf \(quoted.joined(separator: " "))", timeout: timeout
            )
        case .fileSystem(let root):
            let base = root.appendingPathComponent(directory)
            for name in names {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }

    /// Legt ein Verzeichnis an und sagt, ob es vorher noch nicht da war.
    ///
    /// Das ist die Sperre. `mkdir` ohne `-p` ist auf POSIX atomar: Zwei
    /// Rechner, die gleichzeitig danach greifen, bekommen genau einmal `true`.
    /// Ueber ssh ebenso, denn dort laeuft dasselbe `mkdir`.
    ///
    /// Bei SMB und NFS ist die Atomarität eine Zusage des Servers. Das steht so
    /// in `docs/mehrere-rechner.md`, damit niemand mehr erwartet, als die
    /// Freigabe halten kann.
    public func claim(_ name: String) async -> RemoteClaim {
        switch backend {
        case .session(let session, let root):
            let target = path(root, name)
            let parent = (target as NSString).deletingLastPathComponent
            // `mkdir -p` fuer den Elternordner, `mkdir` ohne `-p` fuer den
            // eigentlichen: Nur das Zweite ist der Griff, der genau einmal
            // gelingen darf. `echo` erst danach, also nur bei Erfolg.
            guard
                let result = try? await session.runRemote(
                    "mkdir -p \(SSHCommand.shellQuote(parent)) 2>/dev/null; "
                        + "mkdir \(SSHCommand.shellQuote(target)) 2>/dev/null "
                        + "&& echo synctool-claimed || echo synctool-taken",
                    timeout: timeout
                )
            else { return .unavailable }
            if result.standardOutput.contains("synctool-claimed") { return .claimed }
            if result.standardOutput.contains("synctool-taken") { return .taken }
            return .unavailable
        case .fileSystem(let root):
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: root.path) else { return .unavailable }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // `withIntermediateDirectories: false` wirft, wenn es den Ordner
            // schon gibt. Genau das ist hier die Antwort.
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: false
                )
                return .claimed
            } catch {
                return FileManager.default.fileExists(atPath: url.path) ? .taken : .unavailable
            }
        }
    }

    private func path(_ root: String, _ name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }
}
