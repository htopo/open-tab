import Foundation

/// Decoding that substitutes a default rather than failing.
///
/// The settings document is documented as hand-editable, and it is also the thing
/// carried forward across every future version of the app. A single missing or
/// mistyped key must therefore cost that one value, not the object containing it —
/// otherwise a typo in `panelOpacity` silently discards every other appearance
/// setting alongside it.
///
/// Applied to every settings struct, so leniency holds at each level of nesting
/// rather than only at the top.
extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` if it is absent or malformed.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decode(T.self, forKey: key)) ?? fallback
    }

    /// Decodes an optional field. Absent and malformed both yield nil, which is a
    /// meaningful value for settings like "language" where nil means "system".
    func optionalValue<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: key) ?? nil
    }
}
