import AppKit
import Foundation
import SyncEngine

/// Mount and unmount notifications, as an `AsyncStream` — the USB-drive counterpart of
/// `USBWatcher`. A Kindle 10th generation never offers MTP, so for it the mount is the moment
/// it becomes usable, and the unmount (Eject, or the cable) the moment it stops.
///
/// Like `USBWatcher`, the stream starts by reporting what is already there, so a Kindle that
/// was mounted before launch connects through the same path as one plugged in later.
enum VolumeWatcher {
    enum Event: Sendable {
        case mounted(URL)
        case unmounted(URL)
    }

    /// Observer tokens, held only to be removed again when the stream ends.
    private final class Tokens: @unchecked Sendable {
        var observers: [NSObjectProtocol] = []
    }

    private static func volumeURL(of note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    @MainActor
    static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let tokens = Tokens()

            tokens.observers.append(center.addObserver(
                forName: NSWorkspace.didMountNotification, object: nil, queue: .main
            ) { note in
                if let url = volumeURL(of: note) { continuation.yield(.mounted(url)) }
            })
            tokens.observers.append(center.addObserver(
                forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
            ) { note in
                if let url = volumeURL(of: note) { continuation.yield(.unmounted(url)) }
            })

            for url in KindleVolume.mounted() { continuation.yield(.mounted(url)) }

            continuation.onTermination = { _ in
                Task { @MainActor in
                    for observer in tokens.observers {
                        NSWorkspace.shared.notificationCenter.removeObserver(observer)
                    }
                }
            }
        }
    }
}
