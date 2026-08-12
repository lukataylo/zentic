import Foundation

/// The single JSON configuration used on both sides of the JS bridge.
///
/// Centralised deliberately. Date handling is the classic way a bridge like this
/// rots: JavaScript naturally emits ISO-8601 strings, `JSONDecoder` defaults to
/// seconds-since-epoch `Double`, and the mismatch shows up much later as a
/// decode failure on one page. Every coder on the wire comes from here.
public enum ZenticCoding {
    /// Wire format version. Bump on any breaking change to ``ReaderEvent`` or
    /// ``ReaderCommand``; the JS bundle refuses to talk to a version it does not know.
    public static let wireVersion = 1

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable key order keeps golden-file tests deterministic.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Errors raised by the bridge itself, as opposed to failures reported *by* the
/// page via ``ReaderEvent/failed``.
public enum ReaderBridgeError: Error, Sendable, Equatable {
    /// Page sent a payload this build does not understand.
    case unsupportedWireVersion(received: Int, expected: Int)
    case malformedEvent(String)
    /// Message arrived from an unexpected handler name.
    case unknownHandler(String)
}
