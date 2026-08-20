import AppKit
import SwiftUI
import SyncCore

/// Schale der Einstellungen: links die Profilliste, rechts der Editor.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var pendingDeletion: Profile?

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(state: state, pendingDeletion: $pendingDeletion)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: hostKeySheetBinding) { HostKeySheet(state: state) }
        .alert(
            "Profil löschen?", isPresented: deletionBinding, presenting: pendingDeletion
        ) { profile in
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
            Button("Löschen", role: .destructive) {
                state.removeProfile(id: profile.id)
                pendingDeletion = nil
            }
        } message: { profile in
            Text(
                "„\(profile.name)“ und seine Bestandsliste werden entfernt. Beim nächsten Prüfen "
                    + "eines gleichartigen Profils zählt jede Datei einmalig als neu statt als "
                    + "gelöscht.\n\nDas Passwort im Schlüsselbund und vorhandene Backup-Archive "
                    + "bleiben erhalten."
            )
        }
        .onAppear { state.beginEditing() }
        .onDisappear { state.flushSave() }
    }

    @ViewBuilder
    private var detail: some View {
        if let reason = state.profilesUnreadable {
            // Zehn Minuten in eine Maske zu tippen, die nichts speichert, ist
            // schlimmer als eine gesperrte Maske.
            VStack(spacing: 12) {
                Banner(
                    text: "profiles.json ist nicht lesbar, deshalb wird nichts gespeichert. "
                        + reason,
                    kind: .error
                )
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.profilesFile])
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            switch state.editingSelection {
            case .general:
                GeneralSettingsView(state: state)
            case .profile:
                if let profile = state.editingProfile {
                    ProfileEditorView(state: state, profile: profile)
                        .id(profile.id)
                } else {
                    empty
                }
            case nil:
                empty
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(state.profiles.isEmpty ? "Noch kein Profil angelegt" : "Kein Profil gewählt")
                .font(.title3)
            if state.profiles.isEmpty {
                Text("Ein Profil beschreibt ein Sync-Ziel: Server, Ordner und Anmeldung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Profil anlegen") { state.addProfile() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var hostKeySheetBinding: Binding<Bool> {
        Binding(
            get: { !state.hostKeyCandidates.isEmpty },
            set: { if !$0 { state.hostKeyCandidates = [] } }
        )
    }
}
