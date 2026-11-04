//
//  AgentToolTests.swift
//  OpenClickyTests
//
//  Which command agent tasks run, and when the tour offers Kokoro.
//

import Testing
@testable import OpenClicky

struct AgentToolTests {
    @Test func aHandSetCommandAlwaysWins() {
        let command = ["node", "/repo/agent/dist/cli.js"]
        #expect(AgentTool.command(configured: command, bundledScript: "/app/cli.js", downloadedNode: "/n", systemNode: "/s") == command)
    }

    @Test func theBundledToolRunsOnDownloadedNodeFirstThenThisMacs() {
        let unset = AgentTool.unconfiguredCommand
        #expect(AgentTool.command(configured: unset, bundledScript: "/app/cli.js", downloadedNode: "/n", systemNode: "/s") == ["/n", "/app/cli.js"])
        #expect(AgentTool.command(configured: unset, bundledScript: "/app/cli.js", downloadedNode: nil, systemNode: "/s") == ["/s", "/app/cli.js"])
    }

    @Test func withoutNodeOrABundledToolItFallsBackToWhateverIsLinked() {
        let unset = AgentTool.unconfiguredCommand
        #expect(AgentTool.command(configured: unset, bundledScript: "/app/cli.js", downloadedNode: nil, systemNode: nil) == unset)
        #expect(AgentTool.command(configured: unset, bundledScript: nil, downloadedNode: "/n", systemNode: "/s") == unset)
    }

    @Test func nodeMustBeNewEnough() {
        #expect(AgentTool.isNewEnough(nodeVersion: "v22.0.0\n"))
        #expect(AgentTool.isNewEnough(nodeVersion: "v26.13.0"))
        #expect(!AgentTool.isNewEnough(nodeVersion: "v20.11.1"))
        #expect(!AgentTool.isNewEnough(nodeVersion: "nonsense"))
    }

    @Test func kokoroIsOfferedOnlyToSomeoneOnTheMacsOwnVoice() {
        func offers(installed: Bool = false, voice: SpeechVoiceChoice = .mac, speaks: Bool = true) -> Bool {
            FirstRunTourController.offersNaturalVoice(kokoroInstalled: installed, speakingVoice: voice, kokoroSpeaksLanguage: speaks)
        }
        #expect(offers())
        #expect(!offers(installed: true))
        #expect(!offers(voice: .elevenLabs))
        #expect(!offers(speaks: false))
    }
}
