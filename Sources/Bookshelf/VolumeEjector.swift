import AppKit
import Foundation

/// Ejects a USB-drive Kindle, and when macOS refuses, finds out who is holding it.
///
/// The usual refusal is OSStatus -47 (`fBsyErr`, "file busy"): some process has a file open on
/// the volume. Often it is gone a second later — Spotlight indexing the new books, Finder
/// drawing a thumbnail — so the eject is retried a few times before giving up. If it still
/// fails, `lsof` on the mount point names the processes, which turns "OSStatus error -47" into
/// something the user can act on.
enum VolumeEjector {
    struct Failure: Error, LocalizedError {
        let holders: [String]
        let underlying: Error

        var errorDescription: String? {
            guard !holders.isEmpty else {
                return "macOS says the Kindle is still in use (\(underlying.localizedDescription)). Close any Finder window or app showing it, then try again."
            }
            let list = ListFormatter.localizedString(byJoining: holders)
            return "The Kindle is still in use by \(list). Close it there, then try again."
        }
    }

    /// Up to `attempts` tries, `delay` apart. Runs off the main actor: an unmount can take a
    /// few seconds while macOS flushes the volume.
    static func eject(_ volume: URL, attempts: Int = 4, delay: Duration = .seconds(1.5)) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: delay) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                }.value
                return
            } catch {
                lastError = error
            }
        }
        let holders = await processesUsing(volume)
        throw Failure(holders: holders, underlying: lastError ?? CocoaError(.fileWriteUnknown))
    }

    /// Names of the processes with files open on the volume, ours excluded, friendliest names
    /// first. Empty when `lsof` finds nothing or does not answer within a few seconds.
    static func processesUsing(_ volume: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/lsof")
            // -F pc: machine-readable pid and command lines. Given a mount point, lsof lists
            // every open file on that file system.
            process.arguments = ["-n", "-F", "pc", "--", volume.path(percentEncoded: false)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            // Set before run(), so a process that exits at once still signals.
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            guard (try? process.run()) != nil else { return [] }

            // Drained alongside, so a long listing cannot fill the pipe and stall lsof.
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
            if finished.wait(timeout: .now() + .seconds(5)) == .timedOut {
                process.terminate()
                return []
            }
            guard drained.wait(timeout: .now() + .seconds(2)) == .success else { return [] }

            let output = String(decoding: box.data, as: UTF8.self)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            var names: [String] = []
            var currentPID: Int32 = 0
            for line in output.split(separator: "\n") {
                if line.hasPrefix("p") {
                    currentPID = Int32(line.dropFirst()) ?? 0
                } else if line.hasPrefix("c"), currentPID != ownPID {
                    let name = friendlyName(String(line.dropFirst()))
                    if !names.contains(name) { names.append(name) }
                }
            }
            return names
        }.value
    }

    /// lsof reports truncated command names; these are the ones people meet with a Kindle.
    static func friendlyName(_ command: String) -> String {
        let lower = command.lowercased()
        if lower.hasPrefix("mds") || lower.hasPrefix("mdworker") || lower.hasPrefix("mdsync") {
            return "Spotlight (indexing — usually done within a minute)"
        }
        if lower.hasPrefix("claude") || lower.contains("virtualization") || lower.contains("virtiofs") {
            return "the Claude app (the Kindle is connected to a conversation as a folder — remove it there)"
        }
        if lower == "finder" { return "Finder (an open window or preview)" }
        if lower.hasPrefix("quicklook") || lower.hasPrefix("qlmanage") { return "Quick Look" }
        if lower.hasPrefix("calibre") { return "calibre" }
        return command
    }
}
