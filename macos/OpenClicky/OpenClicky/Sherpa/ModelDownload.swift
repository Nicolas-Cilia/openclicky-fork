//
//  ModelDownload.swift
//  OpenClicky
//
//  Fetching a sherpa-onnx model archive (Kokoro's voice, Parakeet's hearing): download, check
//  against a pinned SHA-256, unpack into Application Support. A resumable download is not worth
//  it: a failed one is retried whole, and GitHub serves both quickly. Also the conditions an
//  automatic download waits for.
//

import CryptoKit
import Foundation
import Network

nonisolated struct ModelDownload: Sendable {
    let url: URL
    let sha256: String
    let bytes: Int64

    /// The free space an automatic download asks for: the archive and the unpacked model side by
    /// side, with room to spare.
    static let automaticDownloadFreeSpace: Int64 = 2_000_000_000

    /// Downloads, checks and unpacks into `folder`, reporting the fraction downloaded.
    func install(into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = try await fetch(into: folder) { written in progress(min(1, Double(written) / Double(bytes))) }
        defer { try? FileManager.default.removeItem(at: archive) }
        try await Self.unpack(archive, into: folder)
    }

    private func fetch(into folder: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let progressDelegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: url, delegate: progressDelegate)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelDownloadError.downloadFailed("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard try Self.sha256(of: destination) == sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw ModelDownloadError.downloadFailed("the download didn't match its checksum")
        }
        return destination
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unpack(_ archive: URL, into folder: URL) async throws {
        try await Task.detached {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", archive.path, "-C", folder.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw ModelDownloadError.unpackFailed("tar exited with \(tar.terminationStatus)") }
        }.value
    }

    // MARK: Automatic downloads

    static func freeSpace() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// A phone hotspot or a metered connection: an automatic download waits for the next launch.
    static func networkIsExpensiveOrConstrained() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status != .satisfied || path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "org.openclicky.model-download.network"))
        }
    }
}

nonisolated enum ModelDownloadError: Error, LocalizedError, Equatable {
    case downloadFailed(String)
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case let .downloadFailed(reason): return "the download failed: \(reason)."
        case let .unpackFailed(reason): return "it couldn't be unpacked: \(reason)."
        }
    }
}

/// What a model download is doing, as Settings shows it.
enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(fraction: Double)
    case unpacking
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .unpacking: return true
        default: return false
        }
    }
}

/// Reports bytes written for one download.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
