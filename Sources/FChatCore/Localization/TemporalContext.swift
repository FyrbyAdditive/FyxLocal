import Foundation

/// Builds a one- or two-line temporal preamble that gets appended to the
/// system instructions on every chat turn. Without this, models routinely
/// invent the date or default to their training cutoff. Including both a
/// machine-readable ISO-8601 stamp and a humanised, locale-formatted line
/// covers both cases.
public struct TemporalContext: Sendable {
    public var date: Date
    public var locale: Locale
    public var timeZone: TimeZone
    public var language: PromptLanguage

    public init(
        date: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        language: PromptLanguage = .resolve()
    ) {
        self.date = date
        self.locale = locale
        self.timeZone = timeZone
        self.language = language
    }

    public func render() -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let iso = isoFormatter.string(from: date)

        let humanFormatter = DateFormatter()
        humanFormatter.locale = locale
        humanFormatter.timeZone = timeZone
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .short
        let human = humanFormatter.string(from: date)

        let tzAbbrev = timeZone.abbreviation(for: date) ?? timeZone.identifier
        let tzName = timeZone.identifier

        switch language {
        case .english:
            return """
            The current date and time is \(human) (\(tzAbbrev), \(tzName)). \
            Machine-readable: \(iso). Use these when the question depends on \
            "today", "now", or how recent something is; do not rely on your \
            training cutoff for date-sensitive answers.
            """
        case .swedish:
            return """
            Aktuellt datum och tid är \(human) (\(tzAbbrev), \(tzName)). \
            Maskinläsbart: \(iso). Använd dessa när frågan beror på "idag", \
            "nu" eller hur färsk en händelse är; förlita dig inte på din \
            träningsdata för datumkänsliga svar.
            """
        }
    }

}
