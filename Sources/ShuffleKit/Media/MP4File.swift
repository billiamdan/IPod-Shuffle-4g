import Foundation

/// Just enough MPEG-4 container parsing to tell where the index sits.
public enum MP4File {
    public struct Atom: Sendable, Equatable {
        public var type: String
        public var offset: Int64
        public var size: Int64
    }

    public static func topLevelAtoms(_ url: URL) throws -> [Atom] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        var atoms: [Atom] = []
        var position: Int64 = 0
        while position + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(position))
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let reader = ByteReader(header)
            var size = Int64(try reader.u32BigEndian(0))
            let type = try reader.tag(4)
            if size == 1, header.count == 16 {
                size = Int64(clamping: try reader.u64BigEndian(8))
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= 8 else { break }
            atoms.append(Atom(type: type, offset: position, size: size))
            position += size
        }
        return atoms
    }

    /// True when the index (`moov`) comes before the audio data (`mdat`), which is how Apple's own
    /// encoders write files. Players that read front to back, like the iPod, need it that way.
    public static func isFastStart(_ url: URL) -> Bool {
        guard let atoms = try? topLevelAtoms(url),
              let index = atoms.firstIndex(where: { $0.type == "moov" }) else { return false }
        guard let media = atoms.firstIndex(where: { $0.type == "mdat" }) else { return true }
        return index < media
    }
}
