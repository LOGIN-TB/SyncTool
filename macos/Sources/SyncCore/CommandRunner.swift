import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { status == 0 }

    /// Erste brauchbare Fehlerzeile fuer die Anzeige im UI.
    public var errorSummary: String {
        let lines = standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? "Beendet mit Status \(status)."
    }
}

public enum CommandError: LocalizedError {
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let reason):
            return "\(path) ließ sich nicht starten: \(reason)"
        }
    }
}

/// Einmalige Kommandos mit eingesammelter Ausgabe. Fuer laufende Uebertragungen
/// mit Fortschritt gibt es `RsyncRunner`.
public enum CommandRunner {
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval = 120
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        standardInput: standardInput,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        standardInput: String?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(executable, error.localizedDescription)
        }

        // Beide Pipes parallel leeren, sonst blockiert der Kindprozess,
        // sobald ein Puffer vollläuft.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()

        for (handle, isStdout) in [
            (outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        // Die Eingabe erst jetzt, und in einem eigenen Faden.
        //
        // Vorher stand sie oben, direkt nach dem Start und vor den Lesern. Bei
        // wenigen Kilobyte faellt das nicht auf, weil alles in den Puffer der
        // Pipe passt. Bei mehr wird daraus eine Verklemmung: Der Kindprozess
        // schreibt nach stdout, niemand liest, sein Puffer laeuft voll, er
        // blockiert und liest deshalb auch nicht weiter aus stdin, waehrend wir
        // dort noch schreiben wollen. Beide warten aufeinander, bis der
        // Zeitablauf den Prozess abschiesst.
        //
        // Gefunden an einem Lauf, der drei Megabyte ueber ssh schicken wollte:
        // Die App stand still und war danach weg, ohne Absturzbericht und ohne
        // eine Zeile im Protokoll.
        if let standardInput, let data = standardInput.data(using: .utf8) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        } else {
            // Ohne Eingabe sofort schliessen, sonst wartet der Kindprozess auf
            // ein Ende, das nie kommt.
            try? inPipe.fileHandleForWriting.close()
        }

        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
