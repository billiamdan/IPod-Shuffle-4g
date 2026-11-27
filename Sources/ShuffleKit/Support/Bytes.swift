import Foundation

public enum BinaryError: ShuffleError, Equatable {
    case outOfBounds(offset: Int, length: Int, size: Int)

    public var description: String {
        switch self {
        case let .outOfBounds(offset, length, size):
            return "read of \(length) bytes at offset \(offset) is outside the \(size)-byte buffer"
        }
    }
}

/// Bounds-checked reader over a byte buffer. Integers are little-endian unless the method says otherwise.
struct ByteReader {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    var count: Int { bytes.count }

    private func require(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, length <= bytes.count, offset <= bytes.count - length else {
            throw BinaryError.outOfBounds(offset: offset, length: length, size: bytes.count)
        }
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try require(offset, 1)
        return bytes[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try require(offset, 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try require(offset, 4)
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = value << 8 | UInt32(bytes[offset + index]) }
        return value
    }

    func u64(_ offset: Int) throws -> UInt64 {
        try require(offset, 8)
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    func u32BigEndian(_ offset: Int) throws -> UInt32 {
        try require(offset, 4)
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(bytes[offset + index]) }
        return value
    }

    func u64BigEndian(_ offset: Int) throws -> UInt64 {
        try require(offset, 8)
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        try require(offset, length)
        return Array(bytes[offset..<offset + length])
    }

    /// Four ASCII characters, as stored (the iPod's magic strings read backwards, e.g. `bdhs`).
    func tag(_ offset: Int) throws -> String {
        String(decoding: try slice(offset, 4), as: UTF8.self)
    }
}

/// Appends little-endian integers and raw bytes.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }

    mutating func tag(_ text: String) {
        precondition(text.utf8.count == 4, "tags are four ASCII characters")
        bytes.append(contentsOf: text.utf8)
    }

    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }

    mutating func zeros(_ count: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: count)) }

    /// Writes `source` into a field of exactly `length` bytes, zero-padded on the right.
    mutating func fixed(_ source: [UInt8], length: Int) {
        precondition(source.count <= length, "field overflow")
        bytes.append(contentsOf: source)
        zeros(length - source.count)
    }
}

/// A short run of bytes that is stored as a hex string in JSON, so manifests stay readable.
public struct HexBytes: Equatable, Sendable, Codable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// `nil` when every byte is zero, so all-zero reserved fields can be left out of the manifest.
    public init?(nonZero bytes: [UInt8]) {
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HexBytes.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a hex string"))
        }
        bytes = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func parse(_ text: String) -> [UInt8]? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let value = UInt8(String(decoding: characters[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            result.append(value)
        }
        return result
    }
}

extension UInt64 {
    /// The 16-digit uppercase form the iPod uses to name VoiceOver recordings.
    public var hexID: String { String(format: "%016llX", self) }
}

/// Errors of this library describe themselves in plain words; the same text is what
/// `localizedDescription` returns, so it can be shown to the user as it is.
public protocol ShuffleError: LocalizedError, CustomStringConvertible {}

extension ShuffleError {
    public var errorDescription: String? { description }
}
