import Foundation

final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.traceview.filewatcher", qos: .userInitiated)

    var onFileChanged: (() -> Void)?

    func watch(url: URL) {
        stop()

        fileDescriptor = open(url.path, O_RDONLY | O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data

            if flags.contains(.rename) || flags.contains(.delete) {
                // File was rotated — try to re-open after a brief delay
                self.handleRotation(url: url)
            } else {
                DispatchQueue.main.async {
                    self.onFileChanged?()
                }
            }
        }

        source.setCancelHandler { [fd = fileDescriptor] in
            close(fd)
        }

        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    private func handleRotation(url: URL) {
        // File was renamed/deleted (log rotation). Poll briefly for it to reappear.
        stop()

        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }

            // Try up to 4 times over 2 seconds
            for attempt in 0..<4 {
                if FileManager.default.fileExists(atPath: url.path) {
                    DispatchQueue.main.async {
                        self.onFileChanged?()
                    }
                    self.watch(url: url)
                    return
                }
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    deinit {
        stop()
    }
}
