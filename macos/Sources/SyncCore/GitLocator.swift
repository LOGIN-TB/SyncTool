import Foundation

public struct GitInfo: Sendable, Equatable {
    public let path: String
    public let versionLine: String

    public var displayName: String { "\(versionLine) (\(path))" }
}

/// Sucht ein git auf dem Rechner.
///
/// `/usr/bin/git` steht bewusst hinten: das ist nur eine Weiche auf die Command
/// Line Tools und oeffnet einen Systemdialog, wenn die fehlen. Deshalb wird der
/// Fund einmal beim Start ermittelt und angezeigt, statt bei jedem Lauf neu
/// danach zu suchen.
public enum GitLocator {
    public static let searchPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ]

    public static func locate() async -> GitInfo? {
        for path in searchPaths {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard
                let result = try? await CommandRunner.run(
                    executable: path, arguments: ["--version"], timeout: 15
                ),
                result.status == 0
            else { continue }

            let firstLine = result.standardOutput
                .split(separator: "\n").first.map(String.init) ?? "git"
            return GitInfo(path: path, versionLine: firstLine.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
