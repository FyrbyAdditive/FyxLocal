import Testing
import Foundation
@testable import FChatCore

@Suite("TemporalContext")
struct TemporalContextTests {
    /// A fixed reference moment used so the test asserts the exact strings
    /// the model will see — independent of when the test runs.
    /// 1_780_000_000 = 2026-05-28T20:26:40Z (Thursday).
    static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func englishContainsISOAndHumanForms() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        )
        let rendered = ctx.render()
        #expect(rendered.contains("2026-05-28T20:26:40Z"))   // ISO-8601
        #expect(rendered.contains("Thursday"))                // dateStyle: .full
        // Foundation canonicalises both `TimeZone(identifier: "UTC")!`
        // abbreviation and identifier to "GMT" on macOS, which is what the
        // LLM actually sees.
        #expect(rendered.contains("GMT"))
        #expect(rendered.contains("training cutoff"))
    }

    @Test func nonGMTZoneSurfacesIANAIdentifier() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            language: .english
        )
        let rendered = ctx.render()
        #expect(rendered.contains("Europe/Stockholm"))
    }

    @Test func swedishUsesSwedishWording() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "sv_SE"),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            language: .swedish
        )
        let rendered = ctx.render()
        #expect(rendered.contains("Aktuellt datum och tid"))
        #expect(rendered.contains("träningsdata"))
        #expect(rendered.contains("Europe/Stockholm"))
    }

    @Test func differentTimeZonesProduceDifferentLocalTimes() {
        let utc = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        ).render()
        let tokyo = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ).render()
        // The ISO stamp is the same (it's the same instant), but the
        // human-formatted local time and tz identifier differ.
        #expect(utc != tokyo)
        #expect(utc.contains("GMT"))
        #expect(tokyo.contains("Asia/Tokyo"))
        // Tokyo runs in JST (+09:00) so the printed local clock-time differs.
        #expect(!tokyo.contains("8:26 PM"))
    }

    @Test func renderingNeverThrowsOrReturnsEmpty() {
        let rendered = TemporalContext().render()
        #expect(!rendered.isEmpty)
        #expect(rendered.count > 60)
    }
}
