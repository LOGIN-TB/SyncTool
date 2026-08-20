import Foundation

public struct RsyncOutcome: Sendable {
    public let status: Int32
    public let items: [ChangeItem]
    public let errorLines: [String]
    public let statsLines: [String]
    /// Symlink-Zeilen, an denen rsync nur Rechte oder Zeiten bemaengelt.
    public let skippedLinkAttributes: Int

    public var succeeded: Bool { status == 0 }

    /// 24 heisst nur: waehrend des Laufs sind Quelldateien verschwunden.
    /// Bei Dev-Ordnern passiert das staendig und ist kein Grund zur Panik.
    public var isWarningOnly: Bool { status == 24 }

    public init(
        status: Int32,
        items: [ChangeItem],
        errorLines: [String],
        statsLines: [String],
        skippedLinkAttributes: Int = 0
    ) {
        self.status = status
        self.items = items
        self.errorLines = errorLines
        self.statsLines = statsLines
        self.skippedLinkAttributes = skippedLinkAttributes
    }
}

public enum RsyncError: LocalizedError {
    case notFound
    case launchFailed(String)
    case failed(status: Int32, detail: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Kein rsync gefunden. Mit `brew install rsync` nachinstallieren."
        case .launchFailed(let reason):
            return "rsync ließ sich nicht starten: \(reason)"
        case .failed(let status, let detail):
            return "rsync endete mit Status \(status): \(detail)"
        case .cancelled:
            return "Abgebrochen."
        }
    }
}

public protocol RsyncExecuting: AnyObject {
    /// `onLine` bekommt jede Ausgabezeile, sobald sie da ist.
    func execute(_ plan: RsyncPlan, onLine: ((String) -> Void)?) async throws -> RsyncOutcome
    func cancel()
}

/// Startet rsync und traegt die Ausgabezeilen zusammen, damit das UI waehrend
/// der Uebertragung etwas anzeigen kann.
///
/// Die Prozessmechanik steckt in `ProcessRunner`. rsync trennt stdout und
/// stderr nicht sinnvoll, deshalb landen hier beide Kanaele in derselben Logik.
public final class RsyncRunner: RsyncExecuting {
    private let process: ProcessRunner

    public init(process: ProcessRunner = ProcessRunner()) {
        self.process = process
    }

    public func cancel() { process.cancel() }
    public func resetCancellation() { process.resetCancellation() }

    public func execute(
        _ plan: RsyncPlan,
        onLine: ((String) -> Void)? = nil
    ) async throws -> RsyncOutcome {
        var items: [ChangeItem] = []
        var errorLines: [String] = []
        var statsLines: [String] = []
        var skippedLinkAttributes = 0
        let collector = NSLock()

        let status: Int32
        do {
            status = try await process.run(
                plan.processPlan,
                onOutput: { line in
                    onLine?(line)
                    collector.lock()
                    switch ItemizeParser.classify(line) {
                    case .item(let item):
                        items.append(item)
                    case .linkAttributesOnly:
                        skippedLinkAttributes += 1
                    case .nothing:
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            statsLines.append(line)
                        }
                    }
                    collector.unlock()
                },
                onError: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onLine?(trimmed)
                    collector.lock()
                    errorLines.append(trimmed)
                    collector.unlock()
                }
            )
        } catch ProcessRunnerError.cancelled {
            throw RsyncError.cancelled
        } catch ProcessRunnerError.launchFailed(_, let reason) {
            throw RsyncError.launchFailed(reason)
        }

        return RsyncOutcome(
            status: status,
            items: items,
            errorLines: errorLines,
            statsLines: statsLines,
            skippedLinkAttributes: skippedLinkAttributes
        )
    }
}
