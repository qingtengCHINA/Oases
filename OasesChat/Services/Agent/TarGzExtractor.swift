import Foundation
import Compression

// MARK: - Archive path rules

/// Path rules shared by the in-app archive extractors (skill zips, skill
/// sync assets, tar.gz). Entry names are untrusted input: an entry may only
/// land strictly inside the extraction root.
enum ArchivePathGuard {
    struct UnsafeEntry: Error, LocalizedError, Equatable {
        let name: String
        var errorDescription: String? { String(localized: "Archive entry has an unsafe path: \(name)", comment: "Skill import error; argument is the offending path inside the archive") }
    }

    /// `name` as a normalized relative path ("a/b/c"), or nil when the entry
    /// must be refused: empty, absolute, containing a `..` component, a NUL
    /// byte or a backslash. `.` components and repeated or trailing slashes
    /// are dropped.
    static func sanitizedRelativePath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"),
              !name.contains("\0"), !name.contains("\\") else { return nil }
        var components: [Substring] = []
        for component in name.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { return nil }
            components.append(component)
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// Host URL for entry `name` under `root`. Throws `UnsafeEntry` for names
    /// `sanitizedRelativePath` refuses, and when a component of the
    /// destination already exists as a symlink — writing through it could
    /// leave `root`.
    static func destination(for name: String, under root: URL) throws -> URL {
        guard let relative = sanitizedRelativePath(name) else { throw UnsafeEntry(name: name) }
        var url = root
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
            var info = stat()
            if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw UnsafeEntry(name: name)
            }
        }
        return url
    }
}

/// Minimal in-process gzip + ustar extractor. Lets us bundle the
/// Alpine rootfs as a single .tar.gz inside the app and unpack it
/// into Application Support on first launch — no libarchive needed,
/// and no broken-symlink install rejection because the symlinks
/// only ever exist inside the sandbox.
///
/// Supports the subset of the ustar / pax format that Alpine uses:
/// regular files, directories, symlinks, hard links (copied).
/// Long names beyond 100 chars are read from the optional GNU
/// `././@LongLink` extension headers.
///
/// Entry names and link targets are untrusted: every entry must land
/// inside `destination` (see `ArchivePathGuard`), symlinks may not point
/// outside it (absolute targets are re-rooted at `destination`), and the
/// decompressed size and entry count are capped. Malformed or truncated
/// archives throw.
enum TarGzExtractor {
    enum ExtractError: Error {
        case gunzipFailed
        case malformedHeader
        case truncated
        case tooLarge
        case unsafeEntry(String)
        case ioFailure(String)
    }

    struct Limits {
        var maxUncompressedBytes = 512 * 1024 * 1024
        var maxEntries = 100_000
    }

    /// Extract `archiveURL` (a .tar.gz file) into `destination`. The
    /// destination is created if missing. Existing entries are
    /// overwritten. Returns the number of file system entries created.
    @discardableResult
    static func extract(archive archiveURL: URL, to destination: URL, limits: Limits = Limits()) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let compressed = try Data(contentsOf: archiveURL)
        let raw = try gunzip(compressed, limit: limits.maxUncompressedBytes)

        var index = 0
        var pendingLongName: String?
        var pendingLongLink: String?
        var entryCount = 0
        let blockSize = 512

        func target(_ name: String) throws -> URL {
            do {
                return try ArchivePathGuard.destination(for: name, under: destination)
            } catch {
                throw ExtractError.unsafeEntry(name)
            }
        }

        while index + blockSize <= raw.count {
            // Two consecutive zero blocks mark end of archive.
            if isAllZero(raw, offset: index) {
                let next = index + blockSize
                if next + blockSize <= raw.count && isAllZero(raw, offset: next) {
                    break
                }
                index += blockSize
                continue
            }

            // Parse the header.
            guard let header = parseHeader(raw, offset: index) else {
                throw ExtractError.malformedHeader
            }
            index += blockSize

            let payloadStart = index
            guard header.size <= raw.count - payloadStart else {
                throw ExtractError.truncated
            }
            let payloadEnd = payloadStart + header.size
            let dataBlocks = (header.size + blockSize - 1) / blockSize
            index += dataBlocks * blockSize

            // GNU long-name extension — capture for the NEXT header.
            if header.typeflag == "L" {
                pendingLongName = trimNulString(raw, range: payloadStart..<payloadEnd)
                continue
            }
            if header.typeflag == "K" {
                pendingLongLink = trimNulString(raw, range: payloadStart..<payloadEnd)
                continue
            }

            let name = pendingLongName ?? header.name
            let linkname = pendingLongLink ?? header.linkname
            pendingLongName = nil
            pendingLongLink = nil

            switch header.typeflag {
            case "5": // directory
                let directory = try target(name)
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            case "2": // symlink — must stay inside the destination
                let link = try target(name)
                guard let relativeName = ArchivePathGuard.sanitizedRelativePath(name),
                      let linkTarget = containedSymlinkTarget(linkname, linkPath: relativeName) else {
                    throw ExtractError.unsafeEntry(name)
                }
                try? fm.removeItem(at: link)
                try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: linkTarget)
            case "1": // hard link — copy the member it names
                let link = try target(name)
                let source = try target(linkname)
                try? fm.removeItem(at: link)
                try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: source, to: link)
            case "0", "7": // regular file ("\0" is normalized to "0")
                let file = try target(name)
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if header.size == 0 {
                    fm.createFile(atPath: file.path, contents: nil)
                } else {
                    let slice = raw.subdata(in: payloadStart..<payloadEnd)
                    try slice.write(to: file)
                }
            default: // pax metadata, devices, FIFOs: nothing to create
                continue
            }
            entryCount += 1
            guard entryCount <= limits.maxEntries else { throw ExtractError.tooLarge }
        }
        return entryCount
    }

    /// Symlink target for a link at `linkPath` (relative to the root) that
    /// stays inside the root, or nil when it would escape. Relative targets
    /// are kept as-is when they stay inside; absolute targets are
    /// rootfs-absolute (e.g. `/bin/busybox`) and are rewritten relative to
    /// the link so they resolve inside the destination, not on the host.
    static func containedSymlinkTarget(_ target: String, linkPath: String) -> String? {
        guard !target.isEmpty, !target.contains("\0") else { return nil }
        let linkDirectory = linkPath.split(separator: "/").dropLast()
        var resolved: [Substring] = target.hasPrefix("/") ? [] : Array(linkDirectory)
        for component in target.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
            default:
                resolved.append(component)
            }
        }
        guard target.hasPrefix("/") else { return target }
        let parts = Array(repeating: "..", count: linkDirectory.count) + resolved.map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    // MARK: - Internals

    private struct Header {
        let name: String
        let size: Int
        let typeflag: String
        let linkname: String
    }

    private static func parseHeader(_ data: Data, offset: Int) -> Header? {
        guard offset + 512 <= data.count else { return nil }
        let block = data.subdata(in: offset..<(offset + 512))
        let name = trimNulString(block, range: 0..<100)
        let sizeStr = trimNulString(block, range: 124..<136)
        let typeflagByte = block[156]
        let linkname = trimNulString(block, range: 157..<257)
        let typeflag = typeflagByte == 0 ? "0" : String(UnicodeScalar(typeflagByte))

        // Size is octal. Strip whitespace/null and parse. (GNU base-256
        // sizes don't parse and are rejected as malformed.)
        let cleaned = sizeStr.trimmingCharacters(in: .whitespaces)
        guard let size = Int(cleaned, radix: 8), size >= 0 else { return nil }
        return Header(name: name, size: size, typeflag: typeflag, linkname: linkname)
    }

    private static func trimNulString(_ data: Data, range: Range<Int>) -> String {
        let absolute = range.lowerBound..<min(range.upperBound, data.count)
        let bytes = data.subdata(in: absolute)
        var end = bytes.count
        for (i, b) in bytes.enumerated() where b == 0 { end = i; break }
        return String(data: bytes.prefix(end), encoding: .utf8) ?? ""
    }

    private static func isAllZero(_ data: Data, offset: Int) -> Bool {
        let end = min(offset + 512, data.count)
        for i in offset..<end where data[i] != 0 { return false }
        return true
    }

    /// Apple's libcompression doesn't speak gzip directly — gzip is
    /// raw DEFLATE with a 10-byte header + 8-byte footer. Strip them
    /// and stream the middle through `COMPRESSION_ZLIB` (raw DEFLATE).
    /// The footer's size field is attacker-controlled, so output is
    /// bounded by `limit` instead of pre-allocated from it.
    static func gunzip(_ input: Data, limit: Int) throws -> Data {
        let gz = input.startIndex == 0 ? input : Data(input)
        guard gz.count > 18, gz[0] == 0x1f, gz[1] == 0x8b, gz[2] == 8 else {
            throw ExtractError.gunzipFailed
        }
        // Skip gzip 10-byte header + optional fields.
        var headerEnd = 10
        let flg = gz[3]
        if flg & 0x04 != 0 { // FEXTRA
            guard headerEnd + 2 <= gz.count else { throw ExtractError.gunzipFailed }
            let xlen = Int(gz[headerEnd]) | (Int(gz[headerEnd + 1]) << 8)
            headerEnd += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME
            while headerEnd < gz.count && gz[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while headerEnd < gz.count && gz[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        if flg & 0x02 != 0 { headerEnd += 2 } // FHCRC
        guard headerEnd < gz.count - 8 else { throw ExtractError.gunzipFailed }

        let deflateBody = gz.subdata(in: headerEnd..<(gz.count - 8))
        return try inflate(deflateBody, limit: limit)
    }

    private static func inflate(_ body: Data, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtractError.gunzipFailed
        }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 256 * 1024
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var output = Data()
        try body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else {
                throw ExtractError.gunzipFailed
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw ExtractError.gunzipFailed }
                let produced = chunkSize - stream.pointee.dst_size
                guard produced <= limit - output.count else { throw ExtractError.tooLarge }
                output.append(chunk, count: produced)
                if status == COMPRESSION_STATUS_END { return }
                // Input exhausted before the end of the DEFLATE stream.
                if produced == 0 && stream.pointee.src_size == 0 { throw ExtractError.truncated }
            }
        }
        guard !output.isEmpty else { throw ExtractError.gunzipFailed }
        return output
    }
}
