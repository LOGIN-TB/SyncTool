import Foundation

/// Alles, was ein Prozessstart braucht. Kennt weder rsync noch zip.
public struct ProcessPlan: Sendable, Equatable {
    /// Woher der Prozess seine Standardeingabe bekommt.
    public enum Input: Sendable, Equatable {
        case null
        /// Eine Datei statt einer Pipe. Wer eine lange Liste hineinreicht und
        /// gleichzeitig die Ausgabe mitliest, verklemmt sich sonst am vollen
        /// Puffer, und ein Abbruch mitten im Schreiben liefert SIGPIPE.
        case file(String)
    }

    public let executable: String
    public let arguments: [String]
    /// `nil` heisst: Umgebung des Elternprozesses uebernehmen.
    public let environment: [String: String]?
    /// Noetig, wenn die Argumente relative Pfade enthalten.
    public let workingDirectory: String?
    public let input: Input

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        input: Input = .null
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
    }

    /// Kommandozeile fuer das Protokoll.
    public var displayCommand: String {
        ([executable] + arguments).map(SSHCommand.shellQuote).joined(separator: " ")
    }
}

public enum ProcessRunnerError: LocalizedError {
    case launchFailed(String, String)
    case inputUnreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let reason):
            return "\(path) ließ sich nicht starten: \(reason)"
        case .inputUnreadable(let path):
            return "Die Eingabedatei \(path) ließ sich nicht öffnen."
        case .cancelled:
            return "Abgebrochen."
        }
    }
}

/// Startet einen Prozess und liest stdout und stderr getrennt zeilenweise mit,
/// waehrend er laeuft. Abbruch jederzeit moeglich.
///
/// Getrennt deshalb, weil nicht jedes Werkzeug beide Kanaele gleich benutzt:
/// zip schreibt seinen Fortschritt auf stdout und die Warnungen auf stderr, und
/// beides in denselben Topf zu werfen macht den Fortschritt unbrauchbar.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = current
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    public func resetCancellation() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Liefert den Beendigungsstatus. Wirft nur, wenn der Prozess gar nicht
    /// erst lief oder abgebrochen wurde.
    public func run(
        _ plan: ProcessPlan,
        onOutput: ((String) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    continuation.resume(
                        returning: try runBlocking(plan, onOutput: onOutput, onError: onError)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlocking(
        _ plan: ProcessPlan,
        onOutput: ((String) -> Void)?,
        onError: ((String) -> Void)?
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        if let environment = plan.environment { process.environment = environment }
        if let directory = plan.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }

        switch plan.input {
        case .null:
            // Ohne geschlossenen stdin wartet ssh im Fehlerfall auf Eingaben.
            process.standardInput = FileHandle.nullDevice
        case .file(let path):
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw ProcessRunnerError.inputUnreadable(path)
            }
            process.standardInput = handle
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        for (handle, callback) in [
            (outPipe.fileHandleForReading, onOutput), (errPipe.fileHandleForReading, onError),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                LineReader.read(handle) { callback?($0) }
                group.leave()
            }
        }

        // Start und Vermerk unter derselben Sperre: Sonst faellt ein Abbruch in
        // die Luecke dazwischen und der Prozess laeuft weiter.
        lock.lock()
        if cancelled {
            lock.unlock()
            throw ProcessRunnerError.cancelled
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            throw ProcessRunnerError.launchFailed(plan.executable, error.localizedDescription)
        }
        current = process
        lock.unlock()

        process.waitUntilExit()
        group.wait()

        lock.lock()
        current = nil
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled { throw ProcessRunnerError.cancelled }
        return process.terminationStatus
    }
}

/// Zerlegt einen Datenstrom in Zeilen, ohne auf das Prozessende zu warten.
enum LineReader {
    static func read(_ handle: FileHandle, onLine: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if let line = String(data: lineData, encoding: .utf8) {
                    onLine(line.hasSuffix("\r") ? String(line.dropLast()) : line)
                }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            onLine(line)
        }
    }
}
