#if !canImport(Darwin)
import Foundation

// Core writes every user-visible string as `String(localized: "…")`. Apple's
// Foundation resolves it against the app's string catalog; the Foundation on
// other platforms has neither `String(localized:)` nor
// `String.LocalizationValue`. This supplies the form Core uses — a literal
// with interpolations and no other arguments — returning the source text
// with the interpolated values in place, which is what Apple's Foundation
// returns too when no catalog translates the key.

extension String {
    struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        struct StringInterpolation: StringInterpolationProtocol {
            var text = ""

            init(literalCapacity: Int, interpolationCount: Int) {
                text.reserveCapacity(literalCapacity)
            }

            mutating func appendLiteral(_ literal: String) {
                text += literal
            }

            mutating func appendInterpolation(_ value: some Any) {
                text += String(describing: value)
            }
        }

        let text: String

        init(stringLiteral value: String) {
            text = value
        }

        init(stringInterpolation: StringInterpolation) {
            text = stringInterpolation.text
        }
    }

    init(localized value: LocalizationValue) {
        self = value.text
    }
}
#endif
