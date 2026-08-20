import SwiftUI
import SyncCore

/// Alles, was bestimmt, was "Pruefen" und "Uebertragen" tun.
///
/// Stammordner und Ausschluesse gehoeren zusammen, weil das eine das andere
/// einschraenkt. Loeschen und Pruefsumme sind Regeln desselben Laufs.
struct SyncTab: View {
    @ObservedObject var state: AppState
    let profile: Profile
    @Binding var touched: Set<ProfileField>
    var focused: FocusState<ProfileField?>.Binding

    @State private var newExclude = ""

    var body: some View {
        Form {
            Section("Lokaler Stammordner") {
                HStack {
                    Text(profile.localRoot.isEmpty ? "Nicht gewählt" : Format.displayPath(profile.localRoot))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(profile.localRoot.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Auswählen …") {
                        guard
                            let path = FolderPicker.choose(
                                message: "Stammordner mit den Projekten wählen",
                                startingAt: profile.localRoot
                            )
                        else { return }
                        binding(\.localRoot).wrappedValue = path
                        state.flushSave()
                    }
                }
                if let issue = profile.localRootIssue(), !profile.localRoot.isEmpty {
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Alles unterhalb dieses Ordners wird abgeglichen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ausschlüsse") {
                BoundedList(count: profile.excludes.count, rowHeight: 22) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(profile.excludes, id: \.self) { pattern in
                            HStack {
                                Text(pattern).font(.callout.monospaced())
                                Spacer()
                                Button {
                                    var edited = profile
                                    edited.excludes.removeAll { $0 == pattern }
                                    state.editingProfile = edited
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                HStack {
                    TextField("Muster", text: $newExclude, prompt: Text("node_modules/"))
                        .onSubmit(addExclude)
                    Button("Hinzufügen", action: addExclude)
                        .disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Alle entfernen") {
                        var edited = profile
                        edited.excludes.removeAll()
                        state.editingProfile = edited
                    }
                    .disabled(profile.excludes.isEmpty)
                }

                Text(
                    "Jedes Muster nimmt Dateien vom Abgleich aus. Leere Liste heißt: alles wird "
                        + "abgeglichen."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                DisclosureGroup("Was heißt das?") {
                    Text(
                        "Ausgeschlossene Dateien erscheinen weder als fehlend noch als "
                            + "abweichend, tauchen in einem FTP-Client aber weiter auf. Nach "
                            + "jedem Prüfen steht im Statusfenster, was dadurch außen vor bleibt. "
                            + "Für das Backup gilt diese Liste nicht."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Löschen") {
                Toggle("Löschungen dürfen übertragen werden", isOn: binding(\.deleteAllowed))
                if profile.deleteAllowed {
                    TextField(
                        "Höchstens so viele Löschungen",
                        value: binding(\.maxDelete), format: .number.grouping(.never)
                    )
                    Text(
                        "rsync bricht ab, statt mehr Dateien zu entfernen. Jeder Lauf mit "
                            + "Löschungen verlangt zusätzlich eine Bestätigung im Statusfenster."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Vergleich") {
                Toggle("Inhalte per Prüfsumme vergleichen", isOn: binding(\.useChecksum))
                Text("Gründlicher, aber deutlich langsamer als der Vergleich über Größe und Zeit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if profile.useChecksum, state.rsyncInfo?.isOpenRsync == true {
                    Text(
                        "openrsync liefert beim Prüfen keine Prüfsummen mit. Der Vergleich läuft "
                            + "dort über Größe und Zeitstempel. `brew install rsync` behebt das."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                DisclosureGroup("Erweitert") {
                    TextField(
                        "rsync-Pfad", text: binding(\.rsyncPath),
                        prompt: Text("automatisch suchen")
                    )
                    Text("Die gefundene Fassung steht unter „Allgemein“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addExclude() {
        var edited = profile
        edited.excludes = ProfileList.normalizedExcludes(edited.excludes + [newExclude])
        state.editingProfile = edited
        newExclude = ""
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        SettingsBinding.make(state: state, profile: profile, keyPath: keyPath)
    }
}
