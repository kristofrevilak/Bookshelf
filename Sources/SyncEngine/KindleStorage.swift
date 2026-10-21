import Foundation
import MTPKit

/// How a Kindle is attached. Recent models (Paperwhite 12, Kindle 2024, Scribe, Colorsoft)
/// speak MTP; everything older — the Kindle 10th generation on firmware 5.18 included — mounts
/// as an ordinary USB drive at `/Volumes/Kindle`.
public enum KindleConnection: String, Sendable {
    case mtp
    case usbDrive

    public var displayName: String {
        switch self {
        case .mtp: return "MTP"
        case .usbDrive: return "USB drive"
        }
    }
}

/// One file or folder directly inside `documents/`.
public struct DeviceFile: Sendable, Hashable {
    public let filename: String
    public let size: UInt64
    public let isFolder: Bool
    public let modified: Date?

    public init(filename: String, size: UInt64, isFolder: Bool, modified: Date? = nil) {
        self.filename = filename
        self.size = size
        self.isFolder = isFolder
        self.modified = modified
    }
}

/// A Kindle as `SyncEngine` sees it, whichever way it is attached.
///
/// The surface is deliberately narrow, because it is also the safety boundary: books and the
/// manifest are written only into `documents/`, the storage root is only ever *read* (for
/// calibre's `metadata.calibre`), and the one other write — a cover thumbnail into
/// `system/thumbnails/` — accepts nothing but a name of the shape the firmware itself uses.
/// Both implementations run every name through `KindleStorageGuard` before touching the device.
///
/// Not Sendable, like the MTP session underneath: instances live inside `DeviceController`.
public protocol KindleStorage: AnyObject {
    var connection: KindleConnection { get }
    var displayName: String { get }
    /// Firmware version, when the device reveals it.
    var firmware: String? { get }

    func space() throws -> (capacity: UInt64, free: UInt64)
    func documentsChildren() throws -> [DeviceFile]
    func readDocument(named name: String) throws -> [UInt8]
    /// The first `length` bytes of a book — enough for record 0 and its EXTH. Implementations
    /// that cannot read partially return the whole file.
    func readDocumentPrefix(named name: String, length: Int) throws -> [UInt8]
    /// A file relative to the storage root, read-only. `nil` when it is not there.
    func readRootFile(_ path: String) throws -> [UInt8]?
    /// Writes into `documents/`, replacing a file of the same name.
    func writeDocument(_ bytes: [UInt8], named name: String, modified: Date) throws
    /// Deletes a file from `documents/`. Folders — the `.sdr` sidecars holding reading progress
    /// and highlights — are never matched.
    func deleteDocument(named name: String) throws

    /// True when the device has a `system/thumbnails/` folder Octavo can write covers into.
    var supportsThumbnails: Bool { get }
    func thumbnailNames() throws -> Set<String>
    func writeThumbnail(_ bytes: [UInt8], named name: String) throws
}

/// Name checks shared by both storages. Throwing rather than sanitising: a bad name here is a
/// bug upstream, and quietly writing *something* to the device is the wrong way to find out.
public enum KindleStorageGuard {
    public static func checkDocumentName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"), !name.contains(":")
        else { throw SyncError.unsafeTarget(name) }
        // A *.bin is what the firmware treats as an update — never write one, anywhere.
        guard !name.lowercased().hasSuffix(".bin") else {
            throw SyncError.unsafeTarget("\(name) — .bin looks like a firmware update")
        }
    }

    /// `thumbnail_<asin>_<cdetype>_portrait.jpg`, and nothing else.
    public static func isThumbnailName(_ name: String) -> Bool {
        name.wholeMatch(of: /thumbnail_[A-Za-z0-9._\-]{1,64}_[A-Z]{4}_portrait\.jpg/) != nil
    }

    public static func checkThumbnailName(_ name: String) throws {
        guard isThumbnailName(name) else { throw SyncError.unsafeTarget(name) }
    }
}

// MARK: - MTP

/// Octavo's original transport, unchanged in behaviour: everything the engine used to do with
/// the session directly now goes through here. Thumbnails are not offered over MTP — that path
/// has not been checked on an MTP Kindle, and writing outside `documents/` is not something to
/// do untested.
public final class MTPKindleStorage: KindleStorage {
    public let session: MTPSession
    public private(set) var storage: MTPStorage
    /// Every write goes under this handle. The storage root — where firmware update files
    /// live — is never a write target.
    public let documentsHandle: UInt32
    public let displayName: String

    public var connection: KindleConnection { .mtp }
    public var firmware: String? { nil }
    public var supportsThumbnails: Bool { false }

    public init(session: MTPSession, name: String = "Kindle") throws {
        self.session = session
        self.displayName = name
        guard let storage = try session.storages().first else { throw SyncError.noStorage }
        self.storage = storage
        guard let documents = try session.object(at: "documents", storageID: storage.id) else {
            throw SyncError.noDocumentsFolder
        }
        self.documentsHandle = documents.id
    }

    public func space() throws -> (capacity: UInt64, free: UInt64) {
        // The storage info is a snapshot; re-query so free space moves after a transfer.
        if let fresh = try? session.storages().first(where: { $0.id == storage.id }) {
            storage = fresh
        }
        return (storage.capacity, storage.freeSpace)
    }

    private func objects() throws -> [MTPObject] {
        try session.children(storageID: storage.id, parent: documentsHandle)
    }

    private func file(named name: String) throws -> MTPObject? {
        try objects().first {
            !$0.isFolder && $0.filename.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    public func documentsChildren() throws -> [DeviceFile] {
        try objects().map {
            DeviceFile(filename: $0.filename, size: $0.size, isFolder: $0.isFolder, modified: $0.modified)
        }
    }

    public func readDocument(named name: String) throws -> [UInt8] {
        guard let object = try file(named: name) else { throw SyncError.missingOnDevice(name) }
        return try session.data(of: object.id)
    }

    public func readDocumentPrefix(named name: String, length: Int) throws -> [UInt8] {
        try readDocument(named: name)
    }

    public func readRootFile(_ path: String) throws -> [UInt8]? {
        guard let object = try session.object(at: path, storageID: storage.id) else { return nil }
        return try? session.data(of: object.id)
    }

    public func writeDocument(_ bytes: [UInt8], named name: String, modified: Date) throws {
        try KindleStorageGuard.checkDocumentName(name)
        if let existing = try file(named: name) { try session.delete(handle: existing.id) }
        try session.sendFile(
            bytes,
            named: name,
            storageID: storage.id,
            parent: documentsHandle,
            modified: modified
        )
    }

    public func deleteDocument(named name: String) throws {
        guard let object = try file(named: name) else { return }
        try session.delete(handle: object.id)
    }

    public func thumbnailNames() throws -> Set<String> { [] }

    public func writeThumbnail(_ bytes: [UInt8], named name: String) throws {
        throw SyncError.unsafeTarget("thumbnails over MTP: \(name)")
    }
}

// MARK: - USB drive

/// A Kindle mounted as a disk — the Kindle 10th generation and everything before the MTP
/// models. Plain file I/O on the mounted volume, so it needs no USB code at all and claims
/// nothing exclusively: Finder can browse the Kindle while Octavo is syncing it.
///
/// The volume is FAT32, which shapes three details: writes go to a hidden temp file and are
/// renamed into place, so an unplugged cable leaves a stray temp file rather than a truncated
/// book the Kindle would try to index; files are fsynced before the rename; and macOS's
/// AppleDouble `._name` companions are hidden from listings and removed with their file.
public final class VolumeKindleStorage: KindleStorage {
    public let root: URL
    let documents: URL
    let thumbnails: URL
    public let displayName: String
    public let firmware: String?

    public var connection: KindleConnection { .usbDrive }

    static let partialSuffix = ".octavo-part"

    public init(root: URL) throws {
        self.root = root
        self.documents = root.appending(path: "documents", directoryHint: .isDirectory)
        self.thumbnails = root.appending(path: "system/thumbnails", directoryHint: .isDirectory)
        guard Self.isDirectory(documents) else { throw SyncError.noDocumentsFolder }
        self.displayName = KindleVolume.volumeName(of: root)
        self.firmware = KindleVolume.firmware(at: root)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Filesystem noise that is not a book and must never be offered as an orphan to remove.
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.hasSuffix(partialSuffix)
            || name == ".Trashes" || name == ".fseventsd" || name == ".Spotlight-V100"
    }

    public func space() throws -> (capacity: UInt64, free: UInt64) {
        let values = try root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return (UInt64(max(values.volumeTotalCapacity ?? 0, 0)), UInt64(max(values.volumeAvailableCapacity ?? 0, 0)))
    }

    public func documentsChildren() throws -> [DeviceFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: keys, options: []
        )
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard !Self.isNoise(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DeviceFile(
                filename: name,
                size: UInt64(max(values?.fileSize ?? 0, 0)),
                isFolder: values?.isDirectory ?? false,
                modified: values?.contentModificationDate
            )
        }
    }

    private func documentURL(_ name: String) throws -> URL {
        try KindleStorageGuard.checkDocumentName(name)
        return documents.appending(path: name, directoryHint: .notDirectory)
    }

    private func regularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public func readDocument(named name: String) throws -> [UInt8] {
        let url = try documentURL(name)
        guard regularFile(url) else { throw SyncError.missingOnDevice(name) }
        return Array(try Data(contentsOf: url))
    }

    public func readDocumentPrefix(named name: String, length: Int) throws -> [UInt8] {
        let url = try documentURL(name)
        guard regularFile(url) else { throw SyncError.missingOnDevice(name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Array(try handle.read(upToCount: length) ?? Data())
    }

    public func readRootFile(_ path: String) throws -> [UInt8]? {
        guard !path.contains("..") else { return nil }
        let url = root.appending(path: path, directoryHint: .notDirectory)
        guard regularFile(url) else { return nil }
        return Array(try Data(contentsOf: url))
    }

    public func writeDocument(_ bytes: [UInt8], named name: String, modified: Date) throws {
        try write(bytes, to: try documentURL(name), modified: modified)
    }

    public func deleteDocument(named name: String) throws {
        let url = try documentURL(name)
        guard regularFile(url) else { return }  // never a folder: .sdr sidecars stay put
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: documents.appending(path: "._\(name)"))
    }

    public var supportsThumbnails: Bool { Self.isDirectory(thumbnails) }

    public func thumbnailNames() throws -> Set<String> {
        guard supportsThumbnails else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: thumbnails.path(percentEncoded: false)))
    }

    public func writeThumbnail(_ bytes: [UInt8], named name: String) throws {
        try KindleStorageGuard.checkThumbnailName(name)
        guard supportsThumbnails else { throw SyncError.unsafeTarget("no system/thumbnails folder") }
        try write(bytes, to: thumbnails.appending(path: name, directoryHint: .notDirectory), modified: Date())
    }

    /// Temp file beside the target, fsync, then rename over it — so a pulled cable never leaves
    /// a half-written book under its real name.
    private func write(_ bytes: [UInt8], to destination: URL, modified: Date) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(UUID().uuidString)\(Self.partialSuffix)")

        guard manager.createFile(atPath: temporary.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path(percentEncoded: false)])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: Data(bytes))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path(percentEncoded: false))
    }
}

// MARK: - Finding a mounted Kindle

public enum KindleVolume {
    /// A volume is a Kindle when it carries the Kindle's own top-level layout: `documents/`
    /// and `system/`, plus either the name "Kindle" or `system/version.txt`. The name alone
    /// is not enough — a USB stick can be called anything.
    public static func isKindle(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        guard VolumeKindleStorage.isDirectory(root.appending(path: "documents")),
              VolumeKindleStorage.isDirectory(root.appending(path: "system"))
        else { return false }
        return volumeName(of: root).localizedCaseInsensitiveContains("kindle")
            || fileManager.fileExists(atPath: root.appending(path: "system/version.txt").path(percentEncoded: false))
    }

    /// Every Kindle currently mounted as a disk.
    public static func mounted() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter(isKindle)
    }

    public static func volumeName(of root: URL) -> String {
        (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? root.lastPathComponent
    }

    /// `system/version.txt` reads like "Kindle 5.18.1 (…) built on …"; the dotted number is
    /// the firmware.
    public static func firmware(at root: URL) -> String? {
        let url = root.appending(path: "system/version.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.firstMatch(of: /\d+\.\d+(\.\d+)*/).map { String($0.output.0) }
    }
}
