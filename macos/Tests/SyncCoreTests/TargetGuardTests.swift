import Foundation
import Testing

@testable import SyncCore

@Suite("Absturzsicherung")
struct TargetGuardTests {

    private func facts(
        direction: SyncDirection = .push,
        source: Int,
        destination: Int = 1000,
        remembered: Int,
        marker: String = "",
        markerFound: Bool? = nil
    ) -> TargetFacts {
        TargetFacts(
            direction: direction,
            sourcePathCount: source,
            destinationPathCount: destination,
            rememberedPathCount: remembered,
            expectedMarker: marker,
            markerFound: markerFound
        )
    }

    // MARK: - Leere Quelle

    @Test("Eine leere Quelle mit Gedächtnis bricht das Löschen ab")
    func emptySourceWithMemoryStops() {
        let problem = TargetGuard.decide(
            facts(source: 0, remembered: 4000), needsDelete: true
        )
        #expect(problem == .unexpectedlyEmpty(direction: .push, remembered: 4000))
    }

    /// Der eigentliche Sinn der Sperre: ohne `--delete` kann nichts
    /// verschwinden, also gibt es nichts zu verhindern.
    @Test("Ohne Löschen läuft derselbe Fall weiter")
    func emptySourceWithoutDeletePasses() {
        #expect(TargetGuard.decide(facts(source: 0, remembered: 4000), needsDelete: false) == nil)
    }

    @Test("Ein echter Erstlauf ohne Gedächtnis läuft")
    func firstRunPasses() {
        #expect(TargetGuard.decide(facts(source: 0, remembered: 0), needsDelete: true) == nil)
    }

    @Test("Eine Quelle mit Inhalt läuft, auch bei großem Gedächtnis")
    func nonEmptySourcePasses() {
        #expect(TargetGuard.decide(facts(source: 1, remembered: 9999), needsDelete: true) == nil)
    }

    /// Die Schwelle ist bewusst niedrig. Wer 25 Dateien abgleicht, verliert
    /// sie genauso wie jemand mit 25.000.
    @Test("Die Schwelle greift genau ab 25 erinnerten Pfaden")
    func thresholdBoundary() {
        #expect(
            TargetGuard.decide(
                facts(source: 0, remembered: TargetGuard.emptyTargetThreshold - 1),
                needsDelete: true
            ) == nil
        )
        #expect(
            TargetGuard.decide(
                facts(source: 0, remembered: TargetGuard.emptyTargetThreshold),
                needsDelete: true
            ) != nil
        )
    }

    @Test("Beim Herunterladen ist die Fernseite die Quelle")
    func pullNamesTheServer() {
        let problem = TargetGuard.decide(
            facts(direction: .pull, source: 0, remembered: 100), needsDelete: true
        )
        #expect(problem == .unexpectedlyEmpty(direction: .pull, remembered: 100))
        #expect(problem?.localizedDescription.contains("Auf dem Server") == true)
    }

    @Test("Beim Hochladen ist dieser Rechner die Quelle")
    func pushNamesThisMachine() {
        let problem = TargetGuard.decide(
            facts(direction: .push, source: 0, remembered: 100), needsDelete: true
        )
        #expect(problem?.localizedDescription.contains("Auf diesem Rechner") == true)
    }

    /// Eine leere Empfaengerseite ist voellig normal: genau das ist ein
    /// Erstlauf.
    @Test("Eine leere Empfängerseite ist kein Grund abzubrechen")
    func emptyDestinationPasses() {
        #expect(
            TargetGuard.decide(
                facts(source: 500, destination: 0, remembered: 500), needsDelete: true
            ) == nil
        )
    }

    // MARK: - Kennung

    @Test("Eine fehlende Kennung bricht ab, auch ohne Löschen")
    func missingMarkerStopsEvenWithoutDelete() {
        let problem = TargetGuard.decide(
            facts(source: 500, remembered: 500, marker: "abc123", markerFound: false),
            needsDelete: false
        )
        #expect(problem == .markerMissing("abc123"))
    }

    @Test("Eine gefundene Kennung läuft")
    func foundMarkerPasses() {
        #expect(
            TargetGuard.decide(
                facts(source: 500, remembered: 500, marker: "abc123", markerFound: true),
                needsDelete: true
            ) == nil
        )
    }

    /// `markerFound: nil` heisst "nicht nachgesehen" und nicht "nicht da".
    /// Ohne diese Unterscheidung wuerde die Sperre bei jedem Ziel greifen, das
    /// noch keine Kennung fuehrt.
    @Test("Nicht nachgesehen ist nicht dasselbe wie nicht gefunden")
    func unknownMarkerPasses() {
        #expect(
            TargetGuard.decide(
                facts(source: 500, remembered: 500, marker: "abc123", markerFound: nil),
                needsDelete: true
            ) == nil
        )
    }

    @Test("Ohne erwartete Kennung wird nicht geprüft")
    func noMarkerExpected() {
        #expect(
            TargetGuard.decide(
                facts(source: 500, remembered: 500, marker: "", markerFound: false),
                needsDelete: true
            ) == nil
        )
    }

    /// Die falsche Freigabe wiegt schwerer als die leere Quelle: wer in den
    /// falschen Ordner schreibt, soll das zuerst erfahren.
    @Test("Die Kennung kommt vor der leeren Quelle")
    func markerWinsOverEmptiness() {
        let problem = TargetGuard.decide(
            facts(source: 0, remembered: 4000, marker: "abc123", markerFound: false),
            needsDelete: true
        )
        #expect(problem == .markerMissing("abc123"))
    }
}
