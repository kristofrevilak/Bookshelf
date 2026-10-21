import CalibreLibrary
import Foundation
import ImageIO
import KindleFormat

// The Kindle cover fix, the same one calibre's Kindle driver applies.
//
// A sideloaded book with an ASIN and cdetype EBOK is filed as a store book, so the firmware
// throws away the thumbnail it made from the embedded cover and goes looking for the cover on
// Amazon under that ASIN — which, for a book Amazon never sold, finds nothing. The cover in the
// library turns into a grey placeholder some time after the first Wi-Fi sync. The fix: write
// `system/thumbnails/thumbnail_<ASIN>_<cdetype>_portrait.jpg` ourselves, keep a copy on the Mac,
// and put it back whenever the firmware deletes it again.
//
// Only offered for USB-drive Kindles: on MTP models the folder is not exposed the same way and
// the path has not been checked on a device.

/// Local copies of every thumbnail written, so a deleted one comes back without re-reading the
/// book or the library cover.
public struct ThumbnailCache: Sendable {
    public let directory: URL

    public static let `default` = ThumbnailCache(
        directory: URL.cachesDirectory.appending(path: "Octavo/thumbnails")
    )

    public init(directory: URL) {
        self.directory = directory
    }

    func load(named name: String) -> Data? {
        guard KindleStorageGuard.isThumbnailName(name) else { return nil }
        return try? Data(contentsOf: directory.appending(path: name))
    }

    func store(_ data: Data, named name: String) {
        guard KindleStorageGuard.isThumbnailName(name) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }
}

public enum CoverThumbnail {
    /// calibre's height for every Kindle since the Paperwhite; the firmware scales from there.
    public static let height = 330

    public static func filename(for identity: MOBIReader.KindleIdentity) -> String {
        "thumbnail_\(identity.asin)_\(identity.cdetype)_portrait.jpg"
    }

    /// A JPEG at most `height` pixels on its long edge — a cover is portrait, so that is its
    /// height. ImageIO, so nothing beyond the SDK.
    public static func jpeg(from image: Data, height: Int = height) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: height,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension SyncEngine {
    /// Record 0 and its EXTH sit at the very start of the file; this is generous.
    static let identityPrefixLength = 256 * 1024
    static let thumbnailExtensions: Set<String> = ["azw3", "azw", "mobi", "prc"]

    public struct ThumbnailReport: Sendable {
        /// Thumbnails the firmware had deleted, put back.
        public var restored = 0
        /// Thumbnails written for the first time for books already on the device.
        public var created = 0

        public var total: Int { restored + created }
    }

    /// Writes the thumbnail for a book that was just sent and returns its name, or `nil` when
    /// the device or the file does not call for one (no thumbnails folder, no ASIN/cdetype,
    /// no cover anywhere).
    func writeThumbnail(for book: Book, bookBytes: Data) throws -> String? {
        guard writesThumbnails, device.supportsThumbnails,
              let identity = MOBIReader.kindleIdentity(of: bookBytes.prefix(Self.identityPrefixLength)),
              let jpeg = coverJPEG(for: book, bookBytes: bookBytes)
        else { return nil }
        let name = CoverThumbnail.filename(for: identity)
        try device.writeThumbnail(Array(jpeg), named: name)
        thumbnailCache.store(jpeg, named: name)
        return name
    }

    /// The library's cover.jpg first — that is the one the user picked — then the cover
    /// embedded in the book.
    func coverJPEG(for book: Book, bookBytes: Data?) -> Data? {
        if let url = book.coverURL(in: library.root),
           let data = try? Data(contentsOf: url),
           let jpeg = CoverThumbnail.jpeg(from: data) {
            return jpeg
        }
        if let bookBytes,
           let cover = try? MOBIReader.metadata(of: bookBytes, fallbackTitle: "").cover,
           let jpeg = CoverThumbnail.jpeg(from: cover) {
            return jpeg
        }
        return nil
    }

    /// Puts back every thumbnail the firmware deleted, for books in the manifest that are
    /// still on the device.
    ///
    /// `recordNew` also covers books whose thumbnail was never recorded — sent by calibre, or
    /// by Octavo before it wrote thumbnails — by reading the ASIN out of the file on the device.
    /// That records the name in the manifest, so it is a write to `documents/` and only happens
    /// as part of a sync; a plain connect passes `false` and touches nothing but thumbnails.
    @discardableResult
    public func restoreThumbnails(for books: [Book], recordNew: Bool) throws -> ThumbnailReport {
        var report = ThumbnailReport()
        guard writesThumbnails, device.supportsThumbnails else { return report }

        var manifest = try loadManifest()
        let present = try device.thumbnailNames()
        let onDevice = Set(try documentsChildren().filter { !$0.isFolder }.map { $0.filename.lowercased() })
        var manifestChanged = false

        for book in books {
            guard var entry = manifest.entries[book.uuid],
                  onDevice.contains(entry.filename.lowercased())
            else { continue }

            let isNew = entry.thumbnail == nil
            if isNew {
                guard recordNew,
                      Self.thumbnailExtensions.contains((entry.filename as NSString).pathExtension.lowercased()),
                      let prefix = try? device.readDocumentPrefix(named: entry.filename, length: Self.identityPrefixLength),
                      let identity = MOBIReader.kindleIdentity(of: Data(prefix))
                else { continue }
                entry.thumbnail = CoverThumbnail.filename(for: identity)
                manifest.entries[book.uuid] = entry
                manifestChanged = true
            }

            guard let name = entry.thumbnail, !present.contains(name),
                  let jpeg = thumbnailCache.load(named: name) ?? coverJPEG(for: book, bookBytes: nil)
            else { continue }
            try device.writeThumbnail(Array(jpeg), named: name)
            thumbnailCache.store(jpeg, named: name)
            if isNew { report.created += 1 } else { report.restored += 1 }
        }

        if manifestChanged { try saveManifest(manifest) }
        return report
    }
}
