import CalibreLibrary
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KindleFormat
@testable import SyncEngine

// A Kindle mounted as a drive is a folder, so — unlike the MTP path — the whole sync can be
// exercised end to end on any Mac: a temp folder laid out like the Kindle 10th generation's
// volume stands in for the device.

/// documents/, system/thumbnails/ and system/version.txt, as the firmware lays them out.
private func makeKindleVolume(thumbnails: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "kindle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appending(path: "documents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appending(path: "system"), withIntermediateDirectories: true)
    if thumbnails {
        try FileManager.default.createDirectory(
            at: root.appending(path: "system/thumbnails"), withIntermediateDirectories: true
        )
    }
    try "Kindle 5.18.1 (4567890123) built on Mon Jun 2 2025\n"
        .write(to: root.appending(path: "system/version.txt"), atomically: true, encoding: .utf8)
    return root
}

/// A real JPEG ImageIO can decode — the thumbnail path rejects anything else.
private func makeJPEG(width: Int = 200, height: Int = 300) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

/// A small AZW3 written by Bookshelf's own KF8 writer, with an ASIN like the sync's conversion gives it.
private func makeAZW3(asin: String?, cover: Data? = nil) -> Data {
    var metadata = EbookMetadata(title: "Thumbnail Test")
    metadata.authors = ["Bookshelf"]
    metadata.asin = asin
    var document = BookDocument(metadata: metadata)
    document.sections.append(BookDocument.Section(
        path: "text.xhtml",
        xhtml: "<html><body><p>\(String(repeating: "Kindle ", count: 400))</p></body></html>"
    ))
    if let cover {
        document.resources.append(cover)
        document.coverResourceIndex = 0
    }
    return KF8Writer.write(document)
}

// MARK: - Guards and detection

@Test func recognisesAKindleVolumeByItsLayout() throws {
    let root = try makeKindleVolume()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(KindleVolume.isKindle(root))
    #expect(KindleVolume.firmware(at: root) == "5.18.1")

    // documents/ alone is not a Kindle — a USB stick can have one.
    let stick = FileManager.default.temporaryDirectory.appending(path: "stick-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stick.appending(path: "documents"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stick) }
    #expect(!KindleVolume.isKindle(stick))
}

@Test func refusesNamesThatLeaveDocumentsOrLookLikeFirmware() {
    for name in ["", ".", "..", "../escape.azw3", "a/b.azw3", "update.bin", "Update_Kindle.BIN", "x:y.azw3"] {
        #expect(throws: SyncError.self, "\(name)") { try KindleStorageGuard.checkDocumentName(name) }
    }
    #expect(throws: Never.self) { try KindleStorageGuard.checkDocumentName("Ремесло - Sergej Dovlatov.azw3") }

    #expect(KindleStorageGuard.isThumbnailName("thumbnail_8b2c5c8e-1e0f-4c1e-9e7a-0d2b9d4c1a11_EBOK_portrait.jpg"))
    #expect(KindleStorageGuard.isThumbnailName("thumbnail_B00TEST123_PDOC_portrait.jpg"))
    #expect(!KindleStorageGuard.isThumbnailName("thumbnail_../../etc_EBOK_portrait.jpg"))
    #expect(!KindleStorageGuard.isThumbnailName("update.bin"))
    #expect(!KindleStorageGuard.isThumbnailName("thumbnail_x_EBOK_portrait.jpg.bin"))
}

// MARK: - The storage

@Test func volumeStorageWritesListsAndDeletesInsideDocuments() throws {
    let root = try makeKindleVolume()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try VolumeKindleStorage(root: root)
    let documents = root.appending(path: "documents")

    try storage.writeDocument(Array("book".utf8), named: "Book - Author.azw3", modified: Date(timeIntervalSince1970: 1_700_000_000))
    // What macOS and the Kindle leave lying around, none of which is a book.
    try Data().write(to: documents.appending(path: "._Book - Author.azw3"))
    try Data().write(to: documents.appending(path: ".DS_Store"))
    try FileManager.default.createDirectory(at: documents.appending(path: "Book - Author.sdr"), withIntermediateDirectories: true)

    let listed = try storage.documentsChildren()
    #expect(Set(listed.map(\.filename)) == ["Book - Author.azw3", "Book - Author.sdr"])
    let book = try #require(listed.first { $0.filename == "Book - Author.azw3" })
    #expect(book.size == 4)
    #expect(!book.isFolder)
    #expect(book.modified == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(try storage.readDocumentPrefix(named: "Book - Author.azw3", length: 2) == Array("bo".utf8))

    // Replacing keeps one file, and no temp file survives the rename.
    try storage.writeDocument(Array("book, again".utf8), named: "Book - Author.azw3", modified: Date())
    #expect(try storage.readDocument(named: "Book - Author.azw3") == Array("book, again".utf8))
    let raw = try FileManager.default.contentsOfDirectory(atPath: documents.path(percentEncoded: false))
    #expect(!raw.contains { $0.hasSuffix(VolumeKindleStorage.partialSuffix) })

    // Deleting a book takes its AppleDouble along and never touches the .sdr sidecar.
    try storage.deleteDocument(named: "Book - Author.azw3")
    try storage.deleteDocument(named: "Book - Author.sdr")
    let after = try FileManager.default.contentsOfDirectory(atPath: documents.path(percentEncoded: false))
    #expect(Set(after) == [".DS_Store", "Book - Author.sdr"])

    #expect(throws: SyncError.self) { try storage.writeDocument([1], named: "update.bin", modified: Date()) }
    #expect(throws: SyncError.self) { try storage.writeThumbnail([1], named: "../documents/x.jpg") }
}

@Test func thumbnailsNeedTheFirmwaresFolder() throws {
    let root = try makeKindleVolume(thumbnails: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try VolumeKindleStorage(root: root)
    #expect(!storage.supportsThumbnails)
    #expect(try storage.thumbnailNames().isEmpty)
}

// MARK: - ASIN and thumbnails

@Test func writerStampsTheASINTheThumbnailIsNamedAfter() throws {
    let file = makeAZW3(asin: "8b2c5c8e-1e0f-4c1e-9e7a-0d2b9d4c1a11")
    let identity = try #require(MOBIReader.kindleIdentity(of: file))
    #expect(identity == MOBIReader.KindleIdentity(asin: "8b2c5c8e-1e0f-4c1e-9e7a-0d2b9d4c1a11", cdetype: "EBOK"))
    #expect(CoverThumbnail.filename(for: identity)
        == "thumbnail_8b2c5c8e-1e0f-4c1e-9e7a-0d2b9d4c1a11_EBOK_portrait.jpg")
    // Record 0 is at the start: the prefix the device path reads is enough.
    #expect(MOBIReader.kindleIdentity(of: file.prefix(SyncEngine.identityPrefixLength)) == identity)

    // No ASIN, no stable name, nothing to fix.
    #expect(MOBIReader.kindleIdentity(of: makeAZW3(asin: nil)) == nil)
}

@Test func thumbnailIsAJPEGAt330PixelsHigh() throws {
    let jpeg = try #require(CoverThumbnail.jpeg(from: try makeJPEG(width: 600, height: 900)))
    #expect(jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.height == CoverThumbnail.height)
    #expect(image.width == 220)
}

// MARK: - End to end

/// Library → USB-drive Kindle: the book lands in documents/, its cover in system/thumbnails/,
/// the manifest remembers both, a re-plan sees nothing to do, and a thumbnail the firmware
/// deletes comes back on the next connect.
@Test func syncsToAMountedKindleAndKeepsTheCover() throws {
    let temp = FileManager.default.temporaryDirectory.appending(path: "bookshelf-e2e-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

    let root = try makeKindleVolume()
    defer { try? FileManager.default.removeItem(at: root) }

    let cover = try makeJPEG()
    let store = try CalibreLibraryStore.create(at: temp.appending(path: "Library"))
    let azw3 = temp.appending(path: "source.azw3")
    try makeAZW3(asin: "asin-e2e-0001", cover: cover).write(to: azw3)
    let book = try store.add(fileAt: azw3, metadata: NewBook(title: "Thumbnail Test", authors: ["Bookshelf"], cover: cover))

    let engine = SyncEngine(library: store, device: try VolumeKindleStorage(root: root))
    engine.conversionCache = ConversionCache(directory: temp.appending(path: "converted"))
    engine.thumbnailCache = ThumbnailCache(directory: temp.appending(path: "thumbnails"))

    let books = try store.books()
    let plan = try engine.plan(books: books, manifest: engine.loadManifest())
    #expect(plan.send.count == 1)
    #expect(plan.send.first?.conversion == nil)

    let manifest = try engine.execute(plan, manifest: engine.loadManifest())
    let entry = try #require(manifest.entries[book.uuid])
    let thumbnail = "thumbnail_asin-e2e-0001_EBOK_portrait.jpg"
    #expect(entry.thumbnail == thumbnail)

    let thumbnailURL = root.appending(path: "system/thumbnails/\(thumbnail)")
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "documents/\(entry.filename)").path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
    #expect(try engine.loadManifest().entries[book.uuid]?.thumbnail == thumbnail)

    let again = try engine.plan(books: books, manifest: engine.loadManifest())
    #expect(again.isEmpty)
    #expect(again.upToDate.count == 1)
    #expect(again.orphans.isEmpty)

    // The firmware deletes it; a connect puts it back without touching documents/.
    try FileManager.default.removeItem(at: thumbnailURL)
    let manifestBefore = try Data(contentsOf: root.appending(path: "documents/\(DeviceManifest.filename)"))
    let report = try engine.restoreThumbnails(for: books, recordNew: false)
    #expect(report.restored == 1)
    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
    #expect(try Data(contentsOf: root.appending(path: "documents/\(DeviceManifest.filename)")) == manifestBefore)
}

/// Books already on the Kindle — calibre's, or sent before thumbnails existed — get one on the
/// next sync, named from the ASIN inside the file on the device.
@Test func backfillsThumbnailsForBooksAlreadyOnTheKindle() throws {
    let temp = FileManager.default.temporaryDirectory.appending(path: "bookshelf-backfill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let root = try makeKindleVolume()
    defer { try? FileManager.default.removeItem(at: root) }

    let cover = try makeJPEG()
    let store = try CalibreLibraryStore.create(at: temp.appending(path: "Library"))
    let azw3 = temp.appending(path: "source.azw3")
    try makeAZW3(asin: "asin-old-0002").write(to: azw3)
    let book = try store.add(fileAt: azw3, metadata: NewBook(title: "Old Book", authors: ["Bookshelf"], cover: cover))

    let engine = SyncEngine(library: store, device: try VolumeKindleStorage(root: root))
    engine.thumbnailCache = ThumbnailCache(directory: temp.appending(path: "thumbnails"))
    engine.writesThumbnails = false
    let books = try store.books()
    _ = try engine.execute(try engine.plan(books: books, manifest: engine.loadManifest()), manifest: engine.loadManifest())
    #expect(try engine.loadManifest().entries[book.uuid]?.thumbnail == nil)

    engine.writesThumbnails = true
    // A connect does not record anything new…
    #expect(try engine.restoreThumbnails(for: books, recordNew: false).total == 0)
    // …a sync does.
    let report = try engine.restoreThumbnails(for: books, recordNew: true)
    #expect(report.created == 1)
    #expect(try engine.loadManifest().entries[book.uuid]?.thumbnail == "thumbnail_asin-old-0002_EBOK_portrait.jpg")
    #expect(FileManager.default.fileExists(
        atPath: root.appending(path: "system/thumbnails/thumbnail_asin-old-0002_EBOK_portrait.jpg").path(percentEncoded: false)
    ))
}

// MARK: - calibre's layout

@Test func acceptsCalibresAuthorFoldersButNothingOutsideThem() {
    #expect(throws: Never.self) { try KindleStorageGuard.checkDocumentPath("Camus, Albert/Stranger, The - Albert Camus.azw3") }
    #expect(throws: Never.self) { try KindleStorageGuard.checkDocumentPath("Flat - Book.azw3") }
    for path in ["../x.azw3", "a/../b.azw3", "/abs.azw3", "a//b.azw3", "Book.sdr/x.azw3",
                 ".hidden/x.azw3", "a/b/c/d.azw3", "Author/update.bin"] {
        #expect(throws: SyncError.self, "\(path)") { try KindleStorageGuard.checkDocumentPath(path) }
    }
}

/// The Kindle 10th generation as calibre leaves it: books in author folders, most of them listed
/// in `metadata.calibre`, one only identifiable by the ASIN inside it, and Amazon's own content in
/// `Downloads/`. Every library book already there must be recognised — none sent twice — and the
/// one that is genuinely new must be the only send.
@Test func recognisesBooksCalibrePutInAuthorFolders() throws {
    let temp = FileManager.default.temporaryDirectory.appending(path: "bookshelf-calibre-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let root = try makeKindleVolume()
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = root.appending(path: "documents")

    let store = try CalibreLibraryStore.create(at: temp.appending(path: "Library"))
    func addBook(_ title: String) throws -> Book {
        let file = temp.appending(path: "\(title).azw3")
        try makeAZW3(asin: nil).write(to: file)
        return try store.add(fileAt: file, metadata: NewBook(title: title, authors: ["Albert Camus"]))
    }
    let listed = try addBook("The Stranger")
    let unlisted = try addBook("The Fall")
    let new = try addBook("The Plague")

    // On the device, the way calibre writes them: author-sort folder, uuid as ASIN.
    let folder = documents.appending(path: "Camus, Albert")
    try FileManager.default.createDirectory(at: folder.appending(path: "Stranger, The - Albert Camus.sdr"), withIntermediateDirectories: true)
    let stranger = makeAZW3(asin: listed.uuid)
    try stranger.write(to: folder.appending(path: "Stranger, The - Albert Camus.azw3"))
    try makeAZW3(asin: unlisted.uuid).write(to: folder.appending(path: "Fall, The - Albert Camus.azw3"))
    try Data().write(to: folder.appending(path: "._Fall, The - Albert Camus.azw3"))
    // Amazon's own downloads: never listed, never matched, never written.
    try FileManager.default.createDirectory(at: documents.appending(path: "Downloads/Items01"), withIntermediateDirectories: true)
    try makeAZW3(asin: new.uuid).write(to: documents.appending(path: "Downloads/Items01/store.azw3"))

    // calibre records the library's last_modified at send time; unchanged since, so not stale.
    let sentStamp = ISO8601DateFormatter().string(from: listed.lastModified.addingTimeInterval(1))
    let calibreManifest = """
    [{"uuid": "\(listed.uuid)", "lpath": "documents/Camus, Albert/Stranger, The - Albert Camus.azw3",
      "size": \(stranger.count), "last_modified": "\(sentStamp)"},
     {"uuid": null, "lpath": "documents/My Clippings.txt", "size": 10}]
    """
    try calibreManifest.write(to: root.appending(path: "metadata.calibre"), atomically: true, encoding: .utf8)

    let engine = SyncEngine(library: store, device: try VolumeKindleStorage(root: root))
    engine.writesThumbnails = false
    let books = try store.books()

    let files = try engine.documentsChildren().filter { !$0.isFolder }.map(\.filename)
    #expect(Set(files) == ["Camus, Albert/Stranger, The - Albert Camus.azw3", "Camus, Albert/Fall, The - Albert Camus.azw3"])

    let manifest = try engine.reconciledManifest(books: books)
    #expect(manifest.entries[listed.uuid]?.filename == "Camus, Albert/Stranger, The - Albert Camus.azw3")
    #expect(manifest.entries[unlisted.uuid]?.filename == "Camus, Albert/Fall, The - Albert Camus.azw3")
    #expect(manifest.entries[new.uuid] == nil)

    let plan = try engine.plan(books: books, manifest: manifest)
    #expect(Set(plan.upToDate.map(\.uuid)) == [listed.uuid, unlisted.uuid])
    #expect(plan.send.map(\.book.uuid) == [new.uuid])
    #expect(plan.orphans.isEmpty)

    // The sync writes the new book flat and records all three; the next plan is empty.
    _ = try engine.execute(plan, manifest: manifest)
    let saved = try engine.loadManifest()
    #expect(saved.entries.count == 3)
    #expect(!(saved.entries[new.uuid]?.filename.contains("/") ?? true))
    #expect(try engine.plan(books: books, manifest: engine.reconciledManifest(books: books)).isEmpty)
    // Amazon's folder was left exactly as it was.
    #expect(try FileManager.default.contentsOfDirectory(atPath: documents.appending(path: "Downloads/Items01").path(percentEncoded: false)) == ["store.azw3"])

    // Removing a nested book takes its ._ companion and leaves the author folder and .sdr.
    try engine.device.deleteDocument(named: "Camus, Albert/Fall, The - Albert Camus.azw3")
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
    #expect(Set(left) == ["Stranger, The - Albert Camus.azw3", "Stranger, The - Albert Camus.sdr"])
}
