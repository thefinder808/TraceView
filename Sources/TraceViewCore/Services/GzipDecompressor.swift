import Foundation

// Thin wrapper around /usr/bin/gunzip. Foundation's built-in decompression
// only covers raw zlib streams; gzip framing would require either libz via
// a C bridging shim or manual header/trailer stripping. Shelling out to the
// system tool is one less dependency and works on every Mac.
//
// Decompresses the entire file into memory. For very large rotated logs
// (tens of MB compressed) this may use significant RAM while parsing, but
// the main-thread load path is still kept responsive because the VM wraps
// this call in Task.detached.
enum GzipDecompressor {

    static func isGzipped(url: URL) -> Bool {
        url.pathExtension.lowercased() == "gz"
    }

    /// Decompress a `.gz` file to raw bytes. Returns nil if `gunzip` fails
    /// (corrupted archive, missing binary, etc.).
    static func decompress(url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe() // discard stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
