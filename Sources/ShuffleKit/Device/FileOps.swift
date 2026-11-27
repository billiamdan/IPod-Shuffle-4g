import CryptoKit
import Foundation

public enum FileOpsError: ShuffleError {
    case posix(operation: String, path: String, code: Int32)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case let .posix(operation, path, code):
            return "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        case let .sizeMismatch(path, expected, actual):
            return "\(path) is \(actual) bytes after copying, expected \(expected)"
        }
    }
}

/// File operations tuned for a FAT volume on a small USB device: explicit flushing,
/// replace-by-rename, and removal of the `._name` sidecar files macOS creates there.
enum FileOps {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes beside the destination, flushes to the device, then renames over the destination,
    /// so the old file stays intact until the new one is complete.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".new")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw FileOpsError.posix(operation: "open", path: temporary.path, code: errno) }
        do {
            try writeAll(descriptor, data, path: temporary.path)
            flush(descriptor)
            close(descriptor)
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw FileOpsError.posix(operation: "rename", path: url.path, code: code)
        }
        removeSidecar(for: temporary)
        removeSidecar(for: url)
    }

    /// Streams a file to the device in chunks, reporting bytes written so far.
    static func copy(from source: URL, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let expected = Int64((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0)

        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw FileOpsError.posix(operation: "open", path: destination.path, code: errno) }
        var written: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try writeAll(descriptor, chunk, path: destination.path)
                written += Int64(chunk.count)
                progress?(written)
            }
            flush(descriptor)
            close(descriptor)
        } catch {
            close(descriptor)
            unlink(destination.path)
            removeSidecar(for: destination)
            throw error
        }
        removeSidecar(for: destination)
        guard written == expected else {
            unlink(destination.path)
            throw FileOpsError.sizeMismatch(path: destination.path, expected: expected, actual: written)
        }
    }

    static func remove(_ url: URL) {
        unlink(url.path)
        removeSidecar(for: url)
    }

    /// macOS stores extended attributes on FAT volumes in a `._name` file next to `name`.
    /// Anything an app writes gets one; the iPod has no use for them.
    static func removeSidecar(for url: URL) {
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        unlink(sidecar.path)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let result = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FileOpsError.posix(operation: "write", path: path, code: errno)
                }
                offset += result
            }
        }
    }

    /// Asks the drive itself to commit; falls back to a plain fsync where that is not supported.
    private static func flush(_ descriptor: Int32) {
        if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
    }
}
