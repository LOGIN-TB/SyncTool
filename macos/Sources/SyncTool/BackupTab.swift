import SwiftUI
import SyncCore

/// Eigenes Ziel, eigene Regeln.
///
/// Ein eigener Reiter erledigt ohne Worte, wofuer sich der Text bisher
/// entschuldigen musste: Die Ausschlussliste des Abgleichs gilt hier nicht.
struct BackupTab: View {
    @ObservedObject var state: AppState
    let profile: Profile

    var body: some View {
        Form {
            Section("Zielordner für die Archive") {
                HStack {
                    Text(
                        profile.backupDestination.isEmpty
                            ? "Nicht gewählt" : Format.displayPath(profile.backupDestination)
                    )
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(profile.backupDestination.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Auswählen …") {
                        guard
                            let path = FolderPicker.choose(
                                message: "Ordner für die Backup-Archive wählen",
                                startingAt: profile.backupDestination
                            )
                        else { return }
                        binding(\.backupDestination).wrappedValue = path
                        state.flushSave()
                    }
                }

                if let problem = destinationProblem {
                    Banner(text: problem, kind: .error)
                }
            }

            Section("Was entsteht") {
                LabeledContent("Dateiname") {
                    Text(BackupName.fileName(root: profile.localRoot, date: Date()))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Text(
                    "Ein zweites Backup am selben Tag bekommt die Uhrzeit angehängt. "
                        + "Überschrieben wird nie."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Umfang") {
                Text(
                    "Alles unterhalb des Stammordners außer Systemdateien wie `.DS_Store`, "
                        + "ausdrücklich einschließlich `node_modules` und `.build`."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("Die Ausschlussliste unter „Abgleich“ gilt hier nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Sofort beim Waehlen melden, nicht erst beim Lauf.
    private var destinationProblem: String? {
        guard !profile.backupDestination.isEmpty, !profile.localRoot.isEmpty,
            BackupTarget.isInside(
                URL(fileURLWithPath: profile.backupDestination, isDirectory: true),
                of: URL(fileURLWithPath: profile.localRoot, isDirectory: true)
            )
        else { return nil }
        return "Dieser Ordner liegt im Stammordner. Das Backup von morgen würde das Archiv von "
            + "heute mit einpacken. Bitte einen Ordner außerhalb wählen."
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        SettingsBinding.make(state: state, profile: profile, keyPath: keyPath)
    }
}

/// Was fuer die ganze App gilt, nicht je Profil.
struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("rsync") {
                LabeledContent("Gefunden") {
                    Text(state.rsyncInfo?.versionLine ?? "kein rsync gefunden")
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Button("Neu suchen") {
                    Task {
                        await state.refreshRsync(
                            preferred: state.editingProfile?.rsyncPath ?? ""
                        )
                    }
                }
                if let warning = state.rsyncWarning {
                    Banner(text: warning, kind: .warning)
                }
            }

            Section("SSH-Schlüssel") {
                Text(
                    state.keyExists
                        ? "Ein Schlüsselpaar liegt unter Application Support/SyncTool."
                        : "Noch kein Schlüsselpaar erzeugt."
                )
                .font(.callout)
                // Es gibt genau eines fuer die ganze App, nicht je Profil.
                Text(
                    "Das Schlüsselpaar gilt für alle Profile. Eingerichtet wird es je Ziel unter "
                        + "„Verbindung“."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Ablage") {
                LabeledContent("Ordner") {
                    Text(Format.displayPath(AppPaths.supportDirectory.path))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
                Text("Dort liegen Profile, Bestandslisten, Host-Keys und das Schlüsselpaar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fassung") {
                LabeledContent("SyncTool") {
                    Text(AppVersion.display)
                        .font(.callout.monospacedDigit())
                        .textSelection(.enabled)
                }
                Text(AppVersion.detailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
