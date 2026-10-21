import CalibreLibrary
import Foundation
import KindleFormat
import MTPKit

/// Formats the stock Kindle firmware can open from a sideloaded file, best first.
public let kindleReadableFormats = ["KFX", "AZW3", "AZW", "MOBI", "PRC", "PDF", "TXT"]

/// Formats Bookshelf can turn into one the Kindle opens, best first.
public let convertibleFormats = ["EPUB", "FB2", "CBZ"]

public struct SendItem: Sendable {
    public let book: Book
    /// The library format being sent — the source format when `conversion` is set.
    public let format: BookFormat
    public let filename: String
    public let reason: Reason
    /// Set when the Kindle cannot read `format`: what it is converted to before sending.
    public var conversion: ConversionTarget?
    /// A device file this send replaces under a different name. Set when the target format
    /// changed, so the old copy is deleted rather than left behind as an orphan.
    public var replaces: String?

    public var needsConversion: Bool { conversion != nil }

    public enum Reason: String, Sendable {
        case new = "new"
        case changed = "changed"
        case missingOnDevice = "gone from device"
    }
}

public struct SyncPlan: Sendable {
    public var send: [SendItem] = []
    public var upToDate: [Book] = []
    /// Books whose only formats the Kindle cannot open (EPUB, CBZ, FB2…).
    public var unsupported: [Book] = []
    /// Files in documents/ that no library book claims.
    public var orphans: [DeviceFile] = []

    public var totalBytes: Int64 { send.reduce(0) { $0 + $1.format.size } }
    public var isEmpty: Bool { send.isEmpty }
}

public enum SyncError: Error, LocalizedError {
    case noStorage
    case noDocumentsFolder
    case fileMissing(URL)
    case missingOnDevice(String)
    case unsafeTarget(String)

    public var errorDescription: String? {
        switch self {
        case .noStorage: return "The device has no available storage"
        case .noDocumentsFolder: return "The device has no documents/ folder"
        case .fileMissing(let url): return "Book file not found: \(url.path(percentEncoded: false))"
        case .missingOnDevice(let name): return "Not on the device: \(name)"
        case .unsafeTarget(let name): return "Write refused: \(name)"
        }
    }
}

public final class SyncEngine {
    public let library: CalibreLibraryStore
    /// The Kindle, over MTP or as a mounted USB drive. Every book write goes into its
    /// `documents/`; see `KindleStorage` for the boundary.
    public let device: KindleStorage
    public var conversionCache = ConversionCache.default
    public var thumbnailCache = ThumbnailCache.default
    /// What EPUB, FB2 and CBZ are converted to. Set by the caller from the user's preference —
    /// `plan` and `pruneConversionCache` read it, but `execute` reads `SendItem.conversion`
    /// instead, so a plan stays coherent even if the setting changes while it runs.
    public var conversionTarget = ConversionTarget.default
    /// Settings ▸ Sync ▸ Fix cover thumbnails. Only has an effect on USB-drive Kindles.
    public var writesThumbnails = true

    /// Where `bookshelf-sync --apply` and the app's "back up before first sync" setting both pull
    /// documents/ to, by default — one constant so the two agree without either hardcoding it.
    public static let defaultBackupDirectory = URL.homeDirectory
        .appending(path: "Library/Application Support/Bookshelf/device-backup")

    public init(library: CalibreLibraryStore, device: KindleStorage) {
        self.library = library
        self.device = device
    }

    /// The MTP path, as Bookshelf always had it.
    public convenience init(library: CalibreLibraryStore, session: MTPSession) throws {
        self.init(library: library, device: try MTPKindleStorage(session: session))
    }

    // MARK: - Manifest

    /// Reads our manifest, falling back to calibre's on the first run.
    public func loadManifest() throws -> DeviceManifest {
        if try documentsChildren().contains(where: { $0.filename == DeviceManifest.filename && !$0.isFolder }),
           let manifest = try? DeviceManifest.decode(device.readDocument(named: DeviceManifest.filename)) {
            return manifest
        }
        if let bytes = try? device.readRootFile("metadata.calibre") {
            return DeviceManifest.adoptingCalibreManifest(bytes)
        }
        return DeviceManifest()
    }

    public func saveManifest(_ manifest: DeviceManifest) throws {
        var updated = manifest
        updated.adoptedFromCalibre = false
        try device.writeDocument(try updated.encoded(), named: DeviceManifest.filename, modified: Date())
    }

    public func documentsChildren() throws -> [DeviceFile] {
        try device.documentsChildren()
    }

    // MARK: - Planning

    public func plan(books: [Book], manifest: DeviceManifest) throws -> SyncPlan {
        let onDevice = try documentsChildren().filter { !$0.isFolder }
        // calibre's manifest lowercases lpath, the filesystem does not.
        var byName: [String: DeviceFile] = [:]
        for file in onDevice { byName[file.filename.lowercased()] = file }

        var plan = SyncPlan()
        var claimed = Set<String>()

        for book in books {
            let readable = bestFormat(for: book)
            let convertible = readable == nil ? convertibleFormat(for: book) : nil
            guard let format = readable ?? convertible else {
                if !book.formats.isEmpty { plan.unsupported.append(book) }
                continue
            }
            let target = readable == nil ? conversionTarget : nil

            let entry = manifest.entries[book.uuid]
            let existing = entry.flatMap { byName[$0.filename.lowercased()] }
            if let existing { claimed.insert(existing.filename.lowercased()) }

            // The manifest's name normally wins, so the books calibre put on the device stay
            // matched. The exception is a converted book whose target format changed: none of
            // the staleness signals notice that, so it would keep its old extension forever.
            //
            // A retarget swaps the extension and *keeps the stem*. It must not re-derive the
            // name: calibre transliterates differently than we do ("Zapovednik - Sergej
            // Dovlatov" against our "Zapoviednik - Sierghiei Dovlatov"), and the .sdr sidecar
            // holding reading progress and highlights is named after the stem. Renaming it
            // would strand the user's place in the book.
            let retarget = entry.map { Self.needsRetarget(entry: $0, target: target) } ?? false
            let filename = entry.map { entry in
                retarget ? Self.retargeted(entry.filename, to: target) : entry.filename
            } ?? Self.targetFilename(for: book, format: format, convertedTo: target)

            guard let entry, let existing else {
                plan.send.append(SendItem(
                    book: book, format: format, filename: filename,
                    reason: entry == nil ? .new : .missingOnDevice,
                    conversion: target
                ))
                continue
            }

            if retarget || Self.isStale(entry: entry, deviceFile: existing, book: book, format: format) {
                plan.send.append(SendItem(
                    book: book, format: format, filename: filename,
                    reason: .changed, conversion: target,
                    replaces: retarget ? entry.filename : nil
                ))
            } else {
                plan.upToDate.append(book)
            }
        }

        plan.orphans = onDevice.filter {
            !claimed.contains($0.filename.lowercased()) && $0.filename != DeviceManifest.filename
        }
        return plan
    }

    /// A device copy is stale when the file on the device is not the one we recorded,
    /// when the library file changed size, or when the book's metadata was edited after
    /// the copy was sent. Byte size alone is not enough: calibre rewrites EXTH metadata
    /// during transfer, so its copies differ from the library file by a few bytes.
    static func isStale(entry: DeviceManifest.Entry, deviceFile: DeviceFile, book: Book, format: BookFormat) -> Bool {
        if entry.deviceSize > 0, entry.deviceSize != Int64(deviceFile.size) { return true }
        if let sourceSize = entry.sourceSize, sourceSize != format.size { return true }
        if let sourceModified = entry.sourceModified, book.lastModified > sourceModified.addingTimeInterval(1) {
            return true
        }
        return false
    }

    /// True when the device copy was converted to a different format than the one now wanted.
    /// Separate from `isStale` because it needs the desired target rather than the recorded
    /// past, and separate from `plan` so it can be tested without a device.
    static func needsRetarget(entry: DeviceManifest.Entry, target: ConversionTarget?) -> Bool {
        guard let target else { return false }
        return (entry.filename as NSString).pathExtension.lowercased() != target.fileExtension
    }

    /// The same name under a different extension. Only the extension changes, so the `.sdr`
    /// sidecar keyed to the stem keeps matching.
    static func retargeted(_ filename: String, to target: ConversionTarget?) -> String {
        guard let target else { return filename }
        return "\((filename as NSString).deletingPathExtension).\(target.fileExtension)"
    }

    public func bestFormat(for book: Book) -> BookFormat? {
        for name in kindleReadableFormats {
            if let format = book.format(name) { return format }
        }
        return nil
    }

    /// The best source to convert when nothing on the book is directly readable.
    public func convertibleFormat(for book: Book) -> BookFormat? {
        for name in convertibleFormats {
            if let format = book.format(name) { return format }
        }
        return nil
    }

    /// calibre's naming, kept so the 31 books already on the device stay matched:
    /// "Title - Author.ext", ASCII-transliterated.
    public static func targetFilename(
        for book: Book,
        format: BookFormat,
        convertedTo target: ConversionTarget? = nil
    ) -> String {
        let title = Self.asciiSanitized(book.title)
        let author = Self.asciiSanitized(book.authorDisplay)
        let stem = "\(title) - \(author)".prefix(180)
        return "\(stem).\(target?.fileExtension ?? format.format.lowercased())"
    }

    /// Kept as a thin alias so the sync engine and the library agree on naming.
    static func asciiSanitized(_ text: String) -> String {
        CalibreFunctions.filenameSafe(text)
    }

    // MARK: - Execution

    public struct Progress: Sendable {
        public let item: SendItem
        public let index: Int
        public let total: Int
    }

    /// Uploads everything in the plan. Only files inside documents/ are ever written.
    ///
    /// `shouldStop` is polled between files; returning true ends the run early and still
    /// saves the manifest, so everything already sent stays recorded. It is declared *after*
    /// `onProgress` because a trailing closure binds by forward scan — put it first and
    /// `bookshelf-sync`'s `execute(plan, manifest:) { progress in … }` would silently try to
    /// bind its progress closure to `shouldStop`.
    @discardableResult
    public func execute(
        _ plan: SyncPlan,
        manifest: DeviceManifest,
        onProgress: ((Progress) -> Void)? = nil,
        shouldStop: (() -> Bool)? = nil
    ) throws -> DeviceManifest {
        var updated = manifest

        for (index, item) in plan.send.enumerated() {
            if shouldStop?() == true { break }
            try KindleStorageGuard.checkDocumentName(item.filename)
            onProgress?(Progress(item: item, index: index, total: plan.send.count))

            // EPUB, FB2 and CBZ become an AZW3 or a MOBI first; the result is cached on disk.
            let source = if let target = item.conversion {
                try conversionCache.converted(
                    for: item.book, source: item.format, target: target, in: library.root
                )
            } else {
                item.book.url(of: item.format, in: library.root)
            }
            guard let data = FileManager.default.contents(atPath: source.path(percentEncoded: false)) else {
                throw SyncError.fileMissing(source)
            }

            // Conversion is the slow non-USB step; checking again here means cancelling
            // during it does not still cost a full upload.
            if shouldStop?() == true { break }

            // Replacing a book means removing the old file first — including the copy under a
            // previous extension when the target format changed, which would otherwise become
            // an orphan. .sdr sidecars are named after the stem, not the extension, so reading
            // progress and annotations survive the rename untouched. writeDocument replaces a
            // file of the same name by itself.
            if let replaced = item.replaces, replaced.caseInsensitiveCompare(item.filename) != .orderedSame {
                try device.deleteDocument(named: replaced)
            }
            try device.writeDocument(Array(data), named: item.filename, modified: item.book.lastModified)

            // Best effort: a missing cover must not fail the book it belongs to.
            let thumbnail = try? writeThumbnail(for: item.book, bookBytes: data)

            updated.entries[item.book.uuid] = DeviceManifest.Entry(
                filename: item.filename,
                deviceSize: Int64(data.count),
                sourceSize: item.format.size,
                sourceModified: item.book.lastModified,
                format: item.format.format,
                sentAt: Date(),
                thumbnail: thumbnail
            )
        }

        // Reached after a `break` too, so a cancelled run keeps what it managed to send.
        // When the cancel was caused by the cable being pulled this write itself fails —
        // harmless, because the next plan() re-reads the device and at worst re-sends a
        // handful of files, which is idempotent.
        try saveManifest(updated)
        return updated
    }

    /// Drops cached conversions no current book would produce — a book removed from the
    /// library, or one re-converted after its source file changed leaves its old cache entry
    /// behind otherwise, since `ConversionCache`'s key folds in size and modification date.
    public func pruneConversionCache(books: [Book]) {
        var wanted: Set<String> = []
        for book in books {
            guard bestFormat(for: book) == nil, let source = convertibleFormat(for: book) else { continue }
            wanted.insert(
                conversionCache.cachedURL(for: book, source: source, target: conversionTarget)
                    .lastPathComponent
            )
        }
        conversionCache.prune(keeping: wanted)
    }

    /// Pulls every file in documents/ to disk. Run before the first write.
    public func backupDocuments(to directory: URL, onFile: ((String, Int, Int) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try documentsChildren().filter { !$0.isFolder }
        for (index, file) in files.enumerated() {
            onFile?(file.filename, index, files.count)
            let destination = directory.appending(path: file.filename)
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            let bytes = try device.readDocument(named: file.filename)
            try Data(bytes).write(to: destination)
        }
    }
}
