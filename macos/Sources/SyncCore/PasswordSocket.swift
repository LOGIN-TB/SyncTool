import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PasswordSocketError: LocalizedError {
    case pathTooLong(String)
    case syscall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Socket-Pfad zu lang für AF_UNIX: \(path)"
        case .syscall(let name, let code):
            return "\(name) fehlgeschlagen: \(String(cString: strerror(code)))"
        }
    }
}

/// Reicht das Passwort an den Askpass-Helfer weiter, ohne es ins Dateisystem
/// oder in die Prozessumgebung zu schreiben. Der Helfer verbindet sich auf
/// einen Unix-Domain-Socket in einem Verzeichnis mit Modus 0700 und liest es dort ab.
public final class PasswordSocket {
    public let path: String

    private let password: String
    private let directory: URL
    private let ownsDirectory: Bool
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let state = NSLock()
    private var stopped = false

    /// `directory` muss bereits mit Modus 0700 existieren. Ohne Angabe legt der
    /// Socket sich ein eigenes Verzeichnis an und raeumt es beim Stoppen weg.
    public init(password: String, directory: URL? = nil) throws {
        self.password = password

        if let directory {
            self.directory = directory
            self.ownsDirectory = false
        } else {
            let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let dir = base.appendingPathComponent(
                "synctool-" + UUID().uuidString.prefix(8), isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            self.directory = dir
            self.ownsDirectory = true
        }
        self.path = self.directory.appendingPathComponent("s").path

        // sun_path fasst auf macOS 104 Bytes inklusive Nullbyte.
        guard self.path.utf8.count < 104 else {
            if ownsDirectory { try? FileManager.default.removeItem(at: self.directory) }
            throw PasswordSocketError.pathTooLong(self.path)
        }
    }

    deinit { stop() }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PasswordSocketError.syscall("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (index, byte) in bytes.enumerated() { dst[index] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw PasswordSocketError.syscall("bind", code)
        }

        chmod(path, 0o600)

        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw PasswordSocketError.syscall("listen", code)
        }

        listenFD = fd
        let worker = Thread { [weak self] in self?.acceptLoop(fd) }
        worker.name = "SyncTool.PasswordSocket"
        worker.start()
        thread = worker
    }

    public func stop() {
        state.lock()
        let alreadyStopped = stopped
        stopped = true
        let fd = listenFD
        listenFD = -1
        state.unlock()

        guard !alreadyStopped else { return }
        if fd >= 0 { close(fd) }
        if ownsDirectory {
            try? FileManager.default.removeItem(at: directory)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private var isStopped: Bool {
        state.lock()
        defer { state.unlock() }
        return stopped
    }

    private func acceptLoop(_ fd: Int32) {
        let payload = Array(password.utf8)
        while !isStopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            payload.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(client)
        }
    }
}
