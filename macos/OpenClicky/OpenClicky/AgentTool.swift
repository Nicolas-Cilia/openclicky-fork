//
//  AgentTool.swift
//  OpenClicky
//
//  How agent tasks reach the openclicky tool. The tool ships inside the app
//  (Contents/Resources/agent-tool, by scripts/embed-agent-tool.sh) but runs on Node.js, which would
//  add about 200 MB to every install and update if it shipped too. So it uses this Mac's Node when
//  that is new enough, and otherwise downloads Node once, only when someone has agent tasks set up.
//  A `cliCommand` set by hand in shell.json always wins.
//

import Combine
import Foundation

nonisolated enum AgentTool {
    /// The value `cliCommand` has when nobody chose one: use the tool in the app.
    static let unconfiguredCommand = ["openclicky"]
    /// package.json's `engines`.
    static let minimumNodeMajor = 22

    static var bundledScript: URL? {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("agent-tool/agent/dist/cli.js"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return script
    }

    /// What to run: a hand-set command, else the bundled tool on the first Node that will do, else
    /// the unconfigured command, which still finds an `openclicky` someone linked onto their PATH.
    static func command(configured: [String], bundledScript: String?, downloadedNode: String?, systemNode: String?) -> [String] {
        guard configured == unconfiguredCommand, let bundledScript, let node = downloadedNode ?? systemNode else { return configured }
        return [node, bundledScript]
    }

    /// True for "v22.1.0" and newer.
    static func isNewEnough(nodeVersion: String) -> Bool {
        let digits = nodeVersion.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
        return (digits.split(separator: ".").first.flatMap { Int($0) } ?? 0) >= minimumNodeMajor
    }

    /// This Mac's Node, if it is new enough. Looked up once per launch.
    static let systemNode: String? = {
        guard let path = (OpenClickyConfiguration.cliProcessEnvironment["PATH"] ?? "").split(separator: ":")
            .map({ "\($0)/node" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && isNewEnough(nodeVersion: String(decoding: data, as: UTF8.self)) ? path : nil
    }()

    // MARK: Node, downloaded

    static let nodeVersion = "22.23.4"

    #if arch(arm64)
    private static let nodePlatform = "darwin-arm64"
    private static let nodeDownload = ModelDownload(
        url: URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-\(nodePlatform).tar.xz")!,
        sha256: "037650d0839f457747396f052073fb48333d31bf5abd3c98b74da20d89ebb1ad", bytes: 25_898_024)
    #else
    private static let nodePlatform = "darwin-x64"
    private static let nodeDownload = ModelDownload(
        url: URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-\(nodePlatform).tar.xz")!,
        sha256: "f42abca7aaac61efc57d49fb42ea84fc53bbeba9a749cb03a291ce6e4e7a69c1", bytes: 27_483_128)
    #endif

    private static var nodeParent: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky/Node", isDirectory: true)
    }
    private static var nodeFolder: URL { nodeParent.appendingPathComponent("node-v\(nodeVersion)-\(nodePlatform)", isDirectory: true) }
    private static var nodeBinary: URL { nodeFolder.appendingPathComponent("bin/node") }

    static var downloadedNode: String? {
        FileManager.default.isExecutableFile(atPath: nodeBinary.path) ? nodeBinary.path : nil
    }

    /// Whether downloading Node is what stands between this Mac and running agent tasks.
    static var needsNodeDownload: Bool {
        OpenClickyConfiguration.settings.cliCommand == unconfiguredCommand && bundledScript != nil
            && downloadedNode == nil && systemNode == nil
    }

    private static let isDownloading = OSAllocatedUnfairLockBox()

    /// Downloads Node if it is needed. Waits for a later try on a metered connection. Only the
    /// `node` program is kept; the archive also holds npm and headers, which nothing here uses.
    static func downloadNodeIfNeeded() async {
        guard needsNodeDownload, isDownloading.begin() else { return }
        defer { isDownloading.end() }
        guard await !ModelDownload.networkIsExpensiveOrConstrained() else { return }
        do {
            try await nodeDownload.install(into: nodeParent) { _ in }
            for item in (try? FileManager.default.contentsOfDirectory(at: nodeFolder, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent != "bin" {
                try? FileManager.default.removeItem(at: item)
            }
            for item in (try? FileManager.default.contentsOfDirectory(at: nodeFolder.appendingPathComponent("bin"), includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent != "node" {
                try? FileManager.default.removeItem(at: item)
            }
            AppLog.append("agent: downloaded node \(nodeVersion)")
        } catch {
            AppLog.append("agent: couldn't download node (\(error.localizedDescription))")
        }
    }
}

/// One download at a time.
private nonisolated final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        isBusy = false
    }
}
