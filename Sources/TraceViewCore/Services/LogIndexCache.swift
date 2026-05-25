import CryptoKit
import Darwin
import Foundation

/// Phase 4.5: on-disk cache for `LogIndex` so re-opening the same big
/// file skips the byte-scan build pass. Cache files live in
/// `~/Library/Caches/com.traceview.app/indexes/` keyed on a SHA-1 of
/// the source file's absolute path. Each cache file is validated
/// against the source's current size + mtime before use — if either
/// has changed, the cache is rejected and a fresh build runs.
///
/// File format (little-endian; native byte order is little-endian on
/// arm64 and x86_64 — the only platforms TraceView targets):
///
///     [Header — 40 bytes]
///       magic:           UInt32  (0x54564C49 'TVLI')
///       version:         UInt32  (1)
///       parserKind:      UInt32  (0=plainText, 1=sccm, 2=csv, 3=other)
///       flags:           UInt32  (bit 0 = hasTimestamps)
///       sourceFileSize:  Int64
///       sourceFileMtime: Double  (timeIntervalSince1970)
///       lineCount:       UInt64
///     [Body]
///       offsets:    lineCount × UInt64
///       levels:     lineCount × UInt8
///       timestamps: lineCount × Double  (only when flag bit 0 set)
///
/// Total: 40 + 8N + N + (8N if timestamps) = 17N + 40 bytes on a
/// PlainText/SCCM index, 9N + 40 on CSV / other.
///
/// Writes are atomic (.tmp + rename). Best-effort: failures are
/// logged and the in-memory index keeps working.
enum LogIndexCache {
    static let magic: UInt32 = 0x5456_4C49  // 'TVLI'
    /// Bumped to 2 in Phase 4.5 PR2 to add the components section. Any
    /// version mismatch invalidates the cache so the rebuild populates
    /// the new fields.
    static let version: UInt32 = 2
    static let headerSize = 40

    /// Flag bits packed into the header's `flags: UInt32`.
    private static let flagHasTimestamps: UInt32 = 0x1
    private static let flagHasComponents: UInt32 = 0x2

    /// Snapshot returned from `tryLoad` — the bytes are read out of the
    /// mmap'd cache file into Swift Arrays so LogIndex's existing
    /// `let offsets/levels/timestamps/componentIndex/uniqueComponents`
    /// properties accept them directly. Allocation + memcpy on a 5 GB-
    /// source-fixture cache is ~30 ms (memory-bandwidth bound), vs
    /// ~5 s to rebuild from scratch.
    struct CachedIndex {
        let offsets: [UInt64]
        let levels: [UInt8]
        let timestamps: [Double]?
        let componentIndex: [UInt16]?
        let uniqueComponents: [String]?
        let parserKind: ParserKind
    }

    /// Resolve the indexes-cache directory itself. Returns nil if the
    /// system Caches directory can't be located. Creates the directory
    /// if it doesn't yet exist. Used by `cacheURL(forSourceURL:)` and
    /// by the Settings "Clear Index Cache" + size-report helpers.
    static func cacheDirectory() -> URL? {
        guard let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let appDir = cachesDir.appendingPathComponent("com.traceview.app/indexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    /// Sum the on-disk size of every cache file in the indexes
    /// directory. Used by the Settings UI to surface "your cache is
    /// using X MB" so the user can decide whether to clear it.
    static func totalCacheSize() -> Int64 {
        guard let dir = cacheDirectory() else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let resources = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = resources.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Delete every cache file in the indexes directory and return the
    /// number of bytes reclaimed. Subsequent opens will rebuild and
    /// repopulate. Used by the Settings UI "Clear Index Cache" button.
    /// We walk and remove individual `.tvidx` / `.tmp` files rather
    /// than the directory itself so an in-flight `write` doesn't race
    /// against directory recreate.
    @discardableResult
    static func clearAll() -> Int64 {
        let reclaimed = totalCacheSize()
        guard let dir = cacheDirectory() else { return 0 }
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "tvidx" || url.pathExtension == "tmp" {
                try? fm.removeItem(at: url)
            }
        }
        return reclaimed
    }

    /// Compute the cache file location for a given source file URL.
    /// Returns nil if the cache directory can't be located.
    static func cacheURL(forSourceURL sourceURL: URL) -> URL? {
        guard let appDir = cacheDirectory() else { return nil }
        let key = sha1Hex(of: sourceURL.path)
        return appDir.appendingPathComponent("\(key).tvidx")
    }

    /// Try to load a cached LogIndex for the given source file. Returns
    /// nil if no cache exists, the cache is corrupted, the source's
    /// size/mtime no longer match, or the parserKind disagrees. Caller
    /// is expected to rebuild and call `write` on a nil return.
    static func tryLoad(forSourceURL sourceURL: URL, parserKind expectedKind: ParserKind) -> CachedIndex? {
        guard let cacheURL = cacheURL(forSourceURL: sourceURL) else { return nil }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        // Mmap the cache file for reading. The Swift Arrays below are
        // built by copying out of this Data; the Data itself can be
        // released after this call returns.
        guard let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              data.count >= headerSize else {
            return nil
        }
        let sourceAttrs = sourceAttributes(of: sourceURL)
        return parse(data: data, sourceSize: sourceAttrs.size, sourceMtime: sourceAttrs.mtime, expectedKind: expectedKind)
    }

    /// Persist a freshly-built LogIndex to disk. Caller is responsible
    /// for calling this only on the build path, not the cache-hit path
    /// (where the existing on-disk copy is already correct).
    /// Best-effort: returns false on any failure, but does not throw.
    @discardableResult
    static func write(
        sourceURL: URL,
        offsets: [UInt64],
        levels: [UInt8],
        timestamps: [Double]?,
        componentIndex: [UInt16]?,
        uniqueComponents: [String]?,
        parserKind: ParserKind
    ) -> Bool {
        guard let cacheURL = cacheURL(forSourceURL: sourceURL) else { return false }
        let attrs = sourceAttributes(of: sourceURL)
        let tempURL = cacheURL.appendingPathExtension("tmp")

        do {
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tempURL) else { return false }
            defer { try? handle.close() }

            // Header.
            var flags: UInt32 = 0
            if timestamps != nil { flags |= flagHasTimestamps }
            if componentIndex != nil && uniqueComponents != nil { flags |= flagHasComponents }

            var header = Data(capacity: headerSize)
            appendUInt32(&header, magic)
            appendUInt32(&header, version)
            appendUInt32(&header, encodeParserKind(parserKind))
            appendUInt32(&header, flags)
            appendInt64(&header, attrs.size)
            appendDouble(&header, attrs.mtime)
            appendUInt64(&header, UInt64(offsets.count))
            try handle.write(contentsOf: header)

            // Offsets.
            try offsets.withUnsafeBufferPointer { buf in
                let data = Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<UInt64>.size)
                try handle.write(contentsOf: data)
            }
            // Levels.
            try levels.withUnsafeBufferPointer { buf in
                let data = Data(bytes: buf.baseAddress!, count: buf.count)
                try handle.write(contentsOf: data)
            }
            // Timestamps (optional).
            if let timestamps {
                try timestamps.withUnsafeBufferPointer { buf in
                    let data = Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Double>.size)
                    try handle.write(contentsOf: data)
                }
            }
            // Components (optional). Layout:
            //   uniqueCount: UInt32
            //   foreach component: length (UInt32) + UTF-8 bytes
            //   componentIndex: lineCount × UInt16
            if let componentIndex, let uniqueComponents {
                var section = Data()
                appendUInt32(&section, UInt32(uniqueComponents.count))
                for comp in uniqueComponents {
                    let bytes = Data(comp.utf8)
                    appendUInt32(&section, UInt32(bytes.count))
                    section.append(bytes)
                }
                try handle.write(contentsOf: section)
                try componentIndex.withUnsafeBufferPointer { buf in
                    let data = Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<UInt16>.size)
                    try handle.write(contentsOf: data)
                }
            }
            try handle.close()

            // Atomic rename. If the destination exists, this replaces it.
            _ = try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.moveItem(at: tempURL, to: cacheURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - Internals

    /// Parse the contents of a cache-file Data into a CachedIndex.
    /// Exposed as `internal` so tests can drive parse failures with
    /// hand-crafted byte blobs.
    static func parse(
        data: Data,
        sourceSize: Int64,
        sourceMtime: Double,
        expectedKind: ParserKind
    ) -> CachedIndex? {
        guard data.count >= headerSize else { return nil }

        let magicRead = readUInt32(data, offset: 0)
        let versionRead = readUInt32(data, offset: 4)
        let parserKindRead = readUInt32(data, offset: 8)
        let flags = readUInt32(data, offset: 12)
        let sourceSizeHeader = readInt64(data, offset: 16)
        let sourceMtimeHeader = readDouble(data, offset: 24)
        let lineCount = Int(readUInt64(data, offset: 32))

        guard magicRead == magic, versionRead == version else { return nil }
        guard decodeParserKind(parserKindRead) == expectedKind else { return nil }
        guard sourceSizeHeader == sourceSize else { return nil }
        // mtime tolerance: 1 ms covers floating-point round-trip noise.
        guard abs(sourceMtimeHeader - sourceMtime) < 0.001 else { return nil }
        let hasTimestamps = (flags & flagHasTimestamps) != 0
        let hasComponents = (flags & flagHasComponents) != 0

        // Slice the fixed-size sections first; components section is
        // variable-length so we parse it from where the fixed sections
        // end.
        let offsetsBytes = lineCount * MemoryLayout<UInt64>.size
        let levelsBytes = lineCount
        let timestampsBytes = hasTimestamps ? lineCount * MemoryLayout<Double>.size : 0
        let fixedEnd = headerSize + offsetsBytes + levelsBytes + timestampsBytes
        guard data.count >= fixedEnd else { return nil }

        let offsetsRange = headerSize..<(headerSize + offsetsBytes)
        let levelsRange = offsetsRange.upperBound..<(offsetsRange.upperBound + levelsBytes)

        let offsets = [UInt64](unsafeUninitializedCapacity: lineCount) { buf, count in
            data.copyBytes(to: buf, from: offsetsRange)
            count = lineCount
        }
        let levels = [UInt8](unsafeUninitializedCapacity: lineCount) { buf, count in
            data.copyBytes(to: buf, from: levelsRange)
            count = lineCount
        }

        var timestamps: [Double]? = nil
        if hasTimestamps {
            let tsRange = levelsRange.upperBound..<(levelsRange.upperBound + timestampsBytes)
            timestamps = [Double](unsafeUninitializedCapacity: lineCount) { buf, count in
                data.copyBytes(to: buf, from: tsRange)
                count = lineCount
            }
        }

        var componentIndex: [UInt16]? = nil
        var uniqueComponents: [String]? = nil
        if hasComponents {
            // Parse the variable-length unique-components table, then
            // the fixed-size componentIndex array.
            var cursor = fixedEnd
            guard cursor + MemoryLayout<UInt32>.size <= data.count else { return nil }
            let uniqueCount = Int(readUInt32(data, offset: cursor))
            cursor += MemoryLayout<UInt32>.size
            var components: [String] = []
            components.reserveCapacity(uniqueCount)
            for _ in 0..<uniqueCount {
                guard cursor + MemoryLayout<UInt32>.size <= data.count else { return nil }
                let length = Int(readUInt32(data, offset: cursor))
                cursor += MemoryLayout<UInt32>.size
                guard cursor + length <= data.count else { return nil }
                let bytes = data.subdata(in: cursor..<(cursor + length))
                components.append(String(data: bytes, encoding: .utf8) ?? "")
                cursor += length
            }
            let componentBytes = lineCount * MemoryLayout<UInt16>.size
            guard cursor + componentBytes == data.count else { return nil }
            let componentRange = cursor..<(cursor + componentBytes)
            componentIndex = [UInt16](unsafeUninitializedCapacity: lineCount) { buf, count in
                data.copyBytes(to: buf, from: componentRange)
                count = lineCount
            }
            uniqueComponents = components
        } else {
            // No components — expected size matches the fixed sections only.
            guard data.count == fixedEnd else { return nil }
        }

        return CachedIndex(
            offsets: offsets,
            levels: levels,
            timestamps: timestamps,
            componentIndex: componentIndex,
            uniqueComponents: uniqueComponents,
            parserKind: decodeParserKind(parserKindRead) ?? expectedKind
        )
    }

    // MARK: - Source-file attribute lookup

    private static func sourceAttributes(of url: URL) -> (size: Int64, mtime: Double) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (0, 0)
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
        return (size, mtime)
    }

    // MARK: - SHA-1 cache key

    private static func sha1Hex(of string: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ParserKind encoding

    private static func encodeParserKind(_ kind: ParserKind) -> UInt32 {
        switch kind {
        case .plainText: return 0
        case .sccm:      return 1
        case .csv:       return 2
        case .other:     return 3
        }
    }

    private static func decodeParserKind(_ raw: UInt32) -> ParserKind? {
        switch raw {
        case 0: return .plainText
        case 1: return .sccm
        case 2: return .csv
        case 3: return .other
        default: return nil
        }
    }

    // MARK: - Little-endian byte readers / writers

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendInt64(_ data: inout Data, _ value: Int64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendDouble(_ data: inout Data, _ value: Double) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + MemoryLayout<UInt32>.size))
        }
        return UInt32(littleEndian: v)
    }
    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        var v: UInt64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + MemoryLayout<UInt64>.size))
        }
        return UInt64(littleEndian: v)
    }
    private static func readInt64(_ data: Data, offset: Int) -> Int64 {
        Int64(bitPattern: readUInt64(data, offset: offset))
    }
    private static func readDouble(_ data: Data, offset: Int) -> Double {
        var v: Double = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + MemoryLayout<Double>.size))
        }
        return v
    }
}
