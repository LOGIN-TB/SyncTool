import SwiftUI
import SyncCore

/// Zeigt die Fingerprints, die der Server anbietet. Erst nach Bestätigung
/// landet ein Key in der known_hosts der App.
struct HostKeySheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Host-Key bestätigen")
                .font(.headline)

            Text(
                "Vergleiche den Fingerprint mit dem, den dein Anbieter nennt. "
                    + "Bei Hetzner steht er in der Storage-Box-Verwaltung."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            ForEach(state.hostKeyCandidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.keyType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(candidate.fingerprint)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Vertrauen") { state.trust(candidate) }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { state.hostKeyCandidates = [] }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
