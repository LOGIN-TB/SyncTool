import Foundation

public struct RsyncInfo: Sendable, Equatable {
    public let path: String
    public let versionLine: String
    /// macOS liefert seit Sequoia openrsync statt rsync 3.x aus.
    public let isOpenRsync: Bool

    public var displayName: String {
        isOpenRsync ? "openrsync (\(path))" : "rsync (\(path))"
    }
}

/// Sucht ein rsync auf dem Rechner. Homebrew zuerst, weil rsync 3.x
/// zuverlaessiger mit den rsync-3.x-Gegenstellen der Storage Boxes spricht.
public enum RsyncLocator {
    public static let searchPaths = [
        "/opt/homebrew/bin/rsync",
        "/usr/local/bin/rsync",
        "/usr/bin/rsync",
    ]

    public static func candidates(preferred: String = "") -> [String] {
        var paths: [String] = []
        if !preferred.isEmpty { paths.append(preferred) }
        paths.append(contentsOf: searchPaths)
        return paths
    }

    public static func locate(preferred: String = "") async -> RsyncInfo? {
        for path in candidates(preferred: preferred) {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard
                let result = try? await CommandRunner.run(
                    executable: path, arguments: ["--version"], timeout: 15
                )
            else { continue }

            let text = result.standardOutput.isEmpty ? result.standardError : result.standardOutput
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
            return RsyncInfo(
                path: path,
                versionLine: firstLine.trimmingCharacters(in: .whitespaces),
                isOpenRsync: text.lowercased().contains("openrsync")
            )
        }
        return nil
    }
}
