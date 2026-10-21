import CalibreLibrary
import Foundation
import KindleFormat
import MTPKit
import SyncEngine

/// Owns the connection to the Kindle — an MTP session, or a mounted USB drive. Everything
/// device-side happens inside this actor, which is why the non-Sendable transport and storage
/// never cross a concurrency boundary.
actor DeviceController {
    struct Snapshot: Sendable, Equatable {
        var name: String
        var freeSpace: UInt64
        var capacity: UInt64
        var booksOnDevice: Int
        var connection: KindleConnection
        var firmware: String?
    }

    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        /// On the bus, but exposing no MTP interface and not mounted as a drive either —
        /// charge-only, or the screen is locked. Informational, not an error, which is what
        /// keeps `.failed` meaningful.
        case waitingForMTP
        case connected(Snapshot)
        case failed(String)

        var snapshot: Snapshot? {
            if case .connected(let snapshot) = self { return snapshot }
            return nil
        }
    }

    private var transport: MTPTransport?
    private var session: MTPSession?
    private var engine: SyncEngine?
    /// Set while connected to a Kindle mounted as a disk; what Eject unmounts.
    private var volume: URL?
    private var libraryRoot: URL

    init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
    }

    /// The engine holds a store open against the old root, so the session goes with it — the
    /// next connect() builds both again.
    func setLibraryRoot(_ url: URL) {
        guard url != libraryRoot else { return }
        disconnect()
        libraryRoot = url
    }

    var isConnected: Bool { engine != nil }
    var volumeURL: URL? { volume }

    func connect() throws -> Snapshot {
        if let engine, let snapshot = try? snapshot(of: engine) { return snapshot }

        disconnect()
        let library = try CalibreLibraryStore(root: libraryRoot, readOnly: true)

        // A Kindle mounted as a disk (the 10th generation and older) needs no USB session
        // and claims nothing exclusively, so it wins whenever one is mounted.
        if let root = KindleVolume.mounted().first {
            let engine = SyncEngine(library: library, device: try VolumeKindleStorage(root: root))
            self.volume = root
            self.engine = engine
            return try snapshot(of: engine)
        }

        let transport = try MTPTransport.openKindle()
        let session = MTPSession(transport: transport)
        try session.open()
        let storage = try MTPKindleStorage(session: session, name: transport.device.product ?? "Kindle")
        let engine = SyncEngine(library: library, device: storage)

        self.transport = transport
        self.session = session
        self.engine = engine
        return try snapshot(of: engine)
    }

    func disconnect() {
        try? session?.close()
        // Explicit rather than waiting for deinit: after a surprise removal the transport
        // may still be referenced, and invalidate() is idempotent.
        transport?.invalidate()
        session = nil
        transport = nil
        engine = nil
        volume = nil
    }

    /// Fresh device figures without rebuilding the session.
    func snapshot() throws -> Snapshot {
        try snapshot(of: requireEngine())
    }

    private func snapshot(of engine: SyncEngine) throws -> Snapshot {
        let files = try engine.documentsChildren().filter { !$0.isFolder }
        let space = try engine.device.space()
        return Snapshot(
            name: engine.device.displayName,
            freeSpace: space.free,
            capacity: space.capacity,
            booksOnDevice: files.count,
            connection: engine.device.connection,
            firmware: engine.device.firmware
        )
    }

    /// `target` is read from `Preferences` on the main actor and handed over as a value —
    /// `Preferences` is `@MainActor` and must never be reached from inside this actor.
    func plan(books: [Book], target: ConversionTarget) throws -> SyncPlan {
        let engine = try requireEngine()
        engine.conversionTarget = target
        return try engine.plan(books: books, manifest: engine.loadManifest())
    }

    /// Sends the planned books. Progress is reported through an isolated callback so the
    /// UI can update while the transfer runs.
    ///
    /// `only` narrows the send to those book ids; `books` is still the whole library, because
    /// cache pruning keeps exactly what `books` would produce and would otherwise throw away
    /// every conversion outside the selection.
    func sync(
        books: [Book],
        only: Set<Book.ID>? = nil,
        target: ConversionTarget,
        pruneCache: Bool = false,
        fixThumbnails: Bool = true,
        shouldStop: @Sendable @escaping () -> Bool,
        progress: @Sendable @escaping (SyncEngine.Progress) -> Void
    ) throws -> SyncPlan {
        let engine = try requireEngine()
        engine.conversionTarget = target
        engine.writesThumbnails = fixThumbnails
        let manifest = try engine.loadManifest()
        let scope = only.map { ids in books.filter { ids.contains($0.id) } } ?? books
        let plan = try engine.plan(books: scope, manifest: manifest)
        if !plan.isEmpty || manifest.adoptedFromCalibre {
            _ = try engine.execute(plan, manifest: manifest, onProgress: progress, shouldStop: shouldStop)
            if pruneCache { engine.pruneConversionCache(books: books) }
        }
        // Also covers books that were already on the device — sent by calibre, or before
        // thumbnails existed. Best effort: a cover is never worth failing a sync over.
        if !shouldStop() { _ = try? engine.restoreThumbnails(for: books, recordNew: true) }
        return plan
    }

    /// Puts back covers the firmware deleted. Writes only into `system/thumbnails/` — the
    /// manifest is left alone — which is why it is safe to run on every connect.
    func restoreThumbnails(books: [Book]) throws -> Int {
        let engine = try requireEngine()
        engine.writesThumbnails = true
        return try engine.restoreThumbnails(for: books, recordNew: false).total
    }

    func backupDocuments(to directory: URL, progress: @Sendable @escaping (String, Int, Int) -> Void) throws {
        try requireEngine().backupDocuments(to: directory, onFile: progress)
    }

    func delete(filename: String) throws {
        try requireEngine().device.deleteDocument(named: filename)
    }

    /// Deletes the device copies of the given books and forgets them in the manifest, so the
    /// next plan sees them as absent rather than stale. `deleteDocument` only ever matches
    /// non-folder entries, which is what keeps `.sdr` reading-progress sidecars safe.
    @discardableResult
    func remove(bookUUIDs: [String]) throws -> Int {
        let engine = try requireEngine()
        var manifest = try engine.loadManifest()
        var removed = 0
        for uuid in bookUUIDs {
            guard let entry = manifest.entries[uuid] else { continue }
            try delete(filename: entry.filename)
            manifest.entries[uuid] = nil
            removed += 1
        }
        if removed > 0 { try engine.saveManifest(manifest) }
        return removed
    }

    private func requireEngine() throws -> SyncEngine {
        if let engine { return engine }
        _ = try connect()
        guard let engine else { throw MTPError.deviceNotFound }
        return engine
    }
}
