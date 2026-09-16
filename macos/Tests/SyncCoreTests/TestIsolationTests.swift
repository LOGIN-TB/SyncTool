import Foundation
import Testing

@testable import SyncCore

/// Dauerwaechter gegen einen Fehler, der im Ordner des Nutzers
/// dreihundert Dateien hinterlassen hat.
///
/// `SyncEngine`, `InventoryStore` und `SyncStateStore` zeigen ohne Angabe auf
/// `~/Library/Application Support/SyncTool`. Ein Test, der das vergisst,
/// schreibt in die echte Konfiguration, und er faellt dabei nicht auf: Er
/// laeuft gruen durch, nur der Ordner waechst.
@Suite("Tests fassen die echte Konfiguration nicht an")
struct TestIsolationTests {
    @Test("Kein Testziel baut eine Maschine ohne eigene Speicher")
    func noTestBuildsAnEngineWithoutItsOwnStores() throws {
        let verzeichnis = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Diese Datei nimmt sich aus: Die Muster, nach denen sie sucht, stehen
        // als Zeichenketten in ihr selbst.
        let eigene = URL(fileURLWithPath: #filePath).lastPathComponent
        let dateien = try FileManager.default.contentsOfDirectory(atPath: verzeichnis.path)
            .filter { $0.hasSuffix(".swift") && $0 != eigene }

        var funde: [String] = []
        for name in dateien {
            let text = try String(
                contentsOf: verzeichnis.appendingPathComponent(name), encoding: .utf8
            )
            // Ein frei stehendes `InventoryStore()` oder `SyncStateStore()`
            // nimmt die Vorbelegung, und die ist der echte Ordner.
            for muster in ["InventoryStore()", "SyncStateStore()"] where text.contains(muster) {
                funde.append("\(name): \(muster)")
            }
            // Und jede Maschine braucht beide Speicher genannt.
            var rest = Substring(text)
            while let start = rest.range(of: "SyncEngine(") {
                var tiefe = 1
                var index = start.upperBound
                while index < rest.endIndex, tiefe > 0 {
                    if rest[index] == "(" { tiefe += 1 }
                    if rest[index] == ")" { tiefe -= 1 }
                    index = rest.index(after: index)
                }
                let block = rest[start.lowerBound..<index]
                if !block.contains("inventoryStore") || !block.contains("stateStore") {
                    funde.append("\(name): SyncEngine ohne eigene Speicher")
                }
                rest = rest[index...]
            }
        }
        #expect(funde.isEmpty, "\(funde)")
    }
}
