//
//  OpenClickyConfigurationTests.swift
//  OpenClickyTests
//
//  Bring your own key: the user's provider keys from shell.json travel as headers and reach the
//  CLI under OpenClicky names, never as OPENAI_API_KEY.
//

import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyConfigurationTests {
    @Test func anOwnKeyIsEnoughForModelCallsWithNoAccount() {
        var settings = OpenClickyShellSettings()
        settings.openaiApiKey = " sk-user "
        settings.anthropicApiKey = ""
        #expect(OpenClickyConfiguration.usesOwnKeys(settings))
        #expect(OpenClickyConfiguration.isConfigured(settings))
        var anthropicOnly = OpenClickyShellSettings()
        anthropicOnly.anthropicApiKey = "ak-user"
        #expect(OpenClickyConfiguration.isConfigured(anthropicOnly))
        var plan = OpenClickyShellSettings()
        plan.useCodexPlan = true
        #expect(OpenClickyConfiguration.isConfigured(plan))
        #expect(!OpenClickyConfiguration.usesOwnKeys(OpenClickyShellSettings()))
        #expect(!OpenClickyConfiguration.isConfigured(OpenClickyShellSettings()))
    }

    @Test func cliEnvironmentCarriesTheUserKeysUnderOpenClickyNames() {
        var settings = OpenClickyShellSettings()
        settings.openaiApiKey = "sk-user"
        let environment = OpenClickyConfiguration.cliProcessEnvironment(from: settings)
        #expect(environment["OPENCLICKY_OPENAI_KEY"] == "sk-user")
        #expect(environment["OPENCLICKY_TOKEN"] == nil)
        #expect(environment["BACKEND_URL"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["OPENCLICKY_ANTHROPIC_KEY"] == nil)
    }

    @Test func resolvedCuaDriverBinAnExplicitSettingWins() {
        var settings = OpenClickyShellSettings()
        settings.cuaDriverBin = " /custom/path/cua-driver "
        let resolved = OpenClickyConfiguration.resolvedCuaDriverBin(
            from: settings,
            environment: ["CUA_DRIVER_BIN": "/should/be/ignored"],
            isExecutable: { _ in true }
        )
        #expect(resolved == "/custom/path/cua-driver")
    }

    @Test func resolvedCuaDriverBinAnExplicitEmptyStringDisablesIt() {
        var settings = OpenClickyShellSettings()
        settings.cuaDriverBin = ""
        let resolved = OpenClickyConfiguration.resolvedCuaDriverBin(
            from: settings,
            environment: ["CUA_DRIVER_BIN": "/should/also/be/ignored"],
            isExecutable: { _ in true }
        )
        #expect(resolved == nil)
    }

    @Test func resolvedCuaDriverBinFallsBackToTheEnvironmentThenAutoDiscovery() {
        let settings = OpenClickyShellSettings()
        // Unset in shell.json: the environment variable wins next.
        #expect(OpenClickyConfiguration.resolvedCuaDriverBin(
            from: settings, environment: ["CUA_DRIVER_BIN": "/env/cua-driver"], isExecutable: { _ in true }
        ) == "/env/cua-driver")
        // Neither set: the first candidate the injected check reports executable wins, never the
        // real filesystem (this must pass whether or not CuaDriver happens to be installed here).
        #expect(OpenClickyConfiguration.resolvedCuaDriverBin(
            from: settings, environment: [:], isExecutable: { $0.hasSuffix("CuaDriver.app/Contents/MacOS/cua-driver") }
        ) == "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
        // Nothing found anywhere: nil.
        #expect(OpenClickyConfiguration.resolvedCuaDriverBin(
            from: settings, environment: [:], isExecutable: { _ in false }
        ) == nil)
    }

    @Test func writableRootsReachTheCLIOnlyWhenTheUserSetsThem() {
        // Unset, the agent applies its own default (the home folder); a list here overrides it.
        #expect(OpenClickyConfiguration.cliProcessEnvironment(from: OpenClickyShellSettings())["OPENCLICKY_WRITABLE_ROOTS"] == nil)

        var settings = OpenClickyShellSettings()
        settings.writableRoots = ["~/Desktop", "/Volumes/Work"]
        let environment = OpenClickyConfiguration.cliProcessEnvironment(from: settings)
        #expect(environment["OPENCLICKY_WRITABLE_ROOTS"] == "~/Desktop,/Volumes/Work")
    }

    // MARK: - shell.json permissions

    /// shell.json carries the session token, refresh token, and the user's own provider keys, so a
    /// fresh write must land at 0600 (owner-only), never the OS default of 0644 (world-readable).
    /// Exercises the pure helper against a temp directory rather than the user's real ~/.openclicky.
    @Test func writingSettingsProducesAnOwnerOnlyFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-settings-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appendingPathComponent("shell.json")

        try OpenClickyConfiguration.writeShellSettingsData(Data("{}".utf8), toFileAt: fileURL)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let filePermissions = fileAttributes[.posixPermissions] as? NSNumber
        #expect(filePermissions?.uint16Value == 0o600)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: temporaryDirectory.path)
        let directoryPermissions = directoryAttributes[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.uint16Value == 0o700)
    }

    /// The case that actually matters on a machine that already has a loosely-permissioned
    /// shell.json from before this fix: the very next write must tighten it, not just a fresh file.
    @Test func writingSettingsTightensAnExistingWorldReadableFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-settings-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let fileURL = temporaryDirectory.appendingPathComponent("shell.json")
        try FileManager.default.createFile(atPath: fileURL.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])

        try OpenClickyConfiguration.writeShellSettingsData(Data("{\"token\":\"tok\"}".utf8), toFileAt: fileURL)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: temporaryDirectory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
    }

    // MARK: - shell.json updates (F-27)

    private func temporarySettingsFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-settings-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("shell.json")
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private func jsonObject(at fileURL: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    }

    /// One wrong-typed field used to make `update` start from the defaults and write them back,
    /// losing every key the person had stored. A file that does not read must be left alone.
    @Test func anUpdateNeverRewritesAFileThatDoesNotDecode() throws {
        let original = #"{"model":"old","sarvamKey":"sk-sarvam","openaiApiKey":"sk-openai","voiceSeconds":"5"}"#
        let fileURL = try temporarySettingsFile(original)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let written = OpenClickyConfiguration.update(fileAt: fileURL) { $0.model = "new" }

        #expect(!written)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == original)
        if case .unreadable = OpenClickyConfiguration.readSettingsFile(at: fileURL) {} else {
            Issue.record("a wrong-typed field must read as unreadable")
        }
    }

    @Test func anUpdateNeverRewritesAFileThatIsNotJSON() throws {
        let original = "{ model: oops"
        let fileURL = try temporarySettingsFile(original)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        #expect(!OpenClickyConfiguration.update(fileAt: fileURL) { $0.model = "new" })
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == original)
    }

    /// The change is merged into the file as it is: fields this build does not know (a newer
    /// build's, or the person's own notes) and everything not changed stay exactly as written.
    @Test func anUpdateKeepsFieldsItDoesNotKnow() throws {
        let fileURL = try temporarySettingsFile(#"{"model":"old","sarvamKey":"sk-sarvam","futureSetting":{"depth":2},"language":"hi"}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let written = OpenClickyConfiguration.update(fileAt: fileURL) { settings in
            settings.model = "new"
            settings.language = nil
        }

        #expect(written)
        let object = try jsonObject(at: fileURL)
        #expect(object["model"] as? String == "new")
        #expect(object["sarvamKey"] as? String == "sk-sarvam")
        #expect((object["futureSetting"] as? [String: Any])?["depth"] as? Int == 2)
        #expect(object["language"] == nil)
        // Defaults the file never spelled out are not written into it.
        #expect(object["voiceSeconds"] == nil)
    }

    /// A short, hand-written shell.json is a normal file: the missing fields take their defaults.
    @Test func aFileWithOnlySomeFieldsReads() throws {
        let fileURL = try temporarySettingsFile(#"{"model":"m","sarvamKey":"sk-sarvam"}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let settings = OpenClickyConfiguration.load(fileURL: fileURL, environment: [:])
        #expect(settings.model == "m")
        #expect(settings.sarvamKey == "sk-sarvam")
        #expect(settings.voiceSeconds == 5)
    }

    /// `OPENCLICKY_MODEL=… open OpenClicky.app` is for this launch only: a save must not write the
    /// override into shell.json.
    @Test func environmentOverridesAreNeverWrittenToTheFile() throws {
        let fileURL = try temporarySettingsFile(#"{"workspace":"/tmp/w"}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let environment = ["OPENCLICKY_MODEL": "local-model"]

        #expect(OpenClickyConfiguration.load(fileURL: fileURL, environment: environment).model == "local-model")
        #expect(OpenClickyConfiguration.update(fileAt: fileURL) { $0.language = "hi" })

        let object = try jsonObject(at: fileURL)
        #expect(object["model"] == nil)
        #expect(object["language"] as? String == "hi")
    }

    /// A file from when the app had accounts still reads, and the next save drops those fields.
    @Test func oldAccountFieldsReadAndAreDroppedOnSave() throws {
        let fileURL = try temporarySettingsFile(#"{"backendUrl":"https://old.example","token":"tok","refreshToken":"r","tokenExpiresAt":1,"accountEmail":"a@b.c","sarvamKey":"sk"}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        #expect(OpenClickyConfiguration.load(fileURL: fileURL, environment: [:]).sarvamKey == "sk")
        #expect(OpenClickyConfiguration.update(fileAt: fileURL) { $0.language = "hi" })

        let object = try jsonObject(at: fileURL)
        for dropped in ["backendUrl", "token", "refreshToken", "tokenExpiresAt", "accountEmail"] {
            #expect(object[dropped] == nil)
        }
        #expect(object["sarvamKey"] as? String == "sk")
    }

    @Test func anUpdateCreatesAMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-settings-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("shell.json")

        #expect(OpenClickyConfiguration.update(fileAt: fileURL) { $0.model = "tok" })
        #expect(OpenClickyConfiguration.load(fileURL: fileURL, environment: [:]).model == "tok")
    }
}
