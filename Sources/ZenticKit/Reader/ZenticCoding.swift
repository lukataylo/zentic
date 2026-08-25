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
    ///
    /// 3: ``Lens`` lost `order`, ``ReaderConfiguration`` lost its seven lens
    /// budgets, ``LensRegion`` gained a fingerprint and ``RegionCandidate`` gained
    /// `itemFields`. The bundle is a resource injected at `document-start`, and a
    /// stale copy of it surviving an app upgrade is the exact scenario this gate
    /// exists for: a v2 bundle reading a v3 lens set would go on believing in a
    /// stacking field nothing sends any more, and apply someone's lenses in an
    /// order the app never chose. Refusing the message is the loud failure; doing
    /// it quietly is not an option worth having.
    public static let wireVersion = 3

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
