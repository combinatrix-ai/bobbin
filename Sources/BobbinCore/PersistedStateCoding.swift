import Foundation

/// The one JSON codec used by both the normal store and demo-data loading.
/// Keeping this configuration in one place makes a copied `state.json` the
/// only input format the demo path needs to understand.
enum PersistedStateCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
