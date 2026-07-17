@preconcurrency import Dispatch
import Foundation
import USBWatcher

private func interruptStream() -> AsyncStream<Void> {
    AsyncStream { continuation in
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            continuation.finish()
        }
        continuation.onTermination = { _ in
            source.cancel()
        }
        source.resume()
    }
}

let watcher = USBWatcher()

do {
    try watcher.start()
    print("Watching for USB device events. Press Ctrl-C to stop.")

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in watcher.events {
                print(
                    "\(event.kind) vendor=\(event.vendorId) product=\(event.productId) " +
                    "serial=\(event.serialNumber ?? "-") name=\(event.productName ?? "-") " +
                    "likelyMTP=\(event.isLikelyMTPDevice.map(String.init) ?? "unknown")"
                )
            }
        }
        group.addTask {
            for await _ in interruptStream() {
                // The stream finishes on the first interrupt.
            }
        }

        await group.next()
        group.cancelAll()
    }

    watcher.stop()
    print("USB watcher stopped.")
} catch {
    FileHandle.standardError.write(Data("usb-watch: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
