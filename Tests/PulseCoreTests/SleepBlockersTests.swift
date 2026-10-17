import Foundation
import Testing
@testable import PulseCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func assertion(pid: Int32 = 729, process: String = "coreaudiod", type: String = "PreventUserIdleSystemSleep",
                       name: String = "x", onBehalfOf: Int32? = nil, minutesAgo: Double = 65,
                       resources: [String] = [], level: Int = 255) -> PowerAssertion {
    PowerAssertion(pid: pid, process: process, type: type, name: name, onBehalfOf: onBehalfOf,
                   started: now.addingTimeInterval(-minutesAgo * 60), resources: resources, level: level)
}

@Suite struct SleepBlockersTests {
    @Test func coreaudiodIsAttributedToTheApp() {
        let list = [assertion(onBehalfOf: 56433, resources: ["audio-out", "BuiltInSpeakerDevice"])]
        let blockers = SleepBlockers.summarize(list, now: now)
        #expect(blockers.count == 1)
        #expect(blockers[0].pid == 56433)
        #expect(blockers[0].reasons == [.speaker])
        #expect(blockers[0].phrase == "keeps the speaker active")
        #expect(blockers[0].since == now.addingTimeInterval(-65 * 60))
    }

    @Test func hidesNormalSystemAssertions() {
        let list = [
            assertion(pid: 542, process: "powerd", name: "Powerd - Prevent sleep while display is on"),
            assertion(pid: 542, process: "powerd", type: "UserIsActive", name: "com.apple.powermanagement.lidopen"),
            assertion(pid: 923, process: "WindowServer", type: "UserIsActive"),
            assertion(pid: 100, process: "bird", type: "BackgroundTask"),
        ]
        #expect(SleepBlockers.summarize(list, now: now).isEmpty)
    }

    @Test func hidesShortAndReleasedAssertions() {
        let list = [
            assertion(onBehalfOf: 1, minutesAgo: 3, resources: ["audio-out"]),
            assertion(onBehalfOf: 2, resources: ["audio-out"], level: 0),
        ]
        #expect(SleepBlockers.summarize(list, now: now).isEmpty)
        #expect(SleepBlockers.summarize(list, now: now, minimumAge: 0).map(\.pid) == [1])
    }

    @Test func groupsHelpersUnderTheirApp() {
        // WebKit.GPU (66054) belongs to Safari (500), Voice Memos (2764) holds the display and the microphone.
        let list = [
            assertion(onBehalfOf: 66054, minutesAgo: 30, resources: ["audio-out", "BuiltInSpeakerDevice"]),
            assertion(pid: 500, process: "Safari", type: "NoIdleSleepAssertion", name: "Video", minutesAgo: 90),
            assertion(pid: 2764, process: "Voice Memos", type: "NoDisplaySleepAssertion", name: "Voice Recording", minutesAgo: 20),
            assertion(onBehalfOf: 2764, minutesAgo: 40, resources: ["audio-in", "BuiltInMicrophoneDevice"]),
        ]
        let blockers = SleepBlockers.summarize(list, now: now, owner: { $0 == 66054 ? 500 : $0 })
        #expect(blockers.map(\.pid) == [500, 2764])
        #expect(blockers[0].reasons == [.speaker, .other])
        #expect(blockers[0].detail == "Video")
        #expect(blockers[0].since == now.addingTimeInterval(-90 * 60))
        #expect(blockers[1].reasons == [.microphone, .display])
        #expect(blockers[1].phrase == "keeps the microphone active and keeps the display on")
    }

    @Test func combinesAudioDevices() {
        let list = [
            assertion(onBehalfOf: 7, resources: ["audio-out", "BuiltInSpeakerDevice"]),
            assertion(onBehalfOf: 7, resources: ["audio-in", "BuiltInMicrophoneDevice"]),
        ]
        let blockers = SleepBlockers.summarize(list, now: now)
        #expect(blockers[0].phrase == "keeps the speaker and the microphone active")
    }

    @Test func externalOutputIsNotTheSpeaker() {
        let list = [assertion(onBehalfOf: 7, resources: ["audio-out", "AppleUSBAudioEngine:beyerdynamic LL Adapter"])]
        #expect(SleepBlockers.summarize(list, now: now)[0].reasons == [.audioOut])
    }

    @Test func skipsOwnProcess() {
        let list = [assertion(pid: 42, process: "Pulse", type: "PreventUserIdleSystemSleep")]
        #expect(SleepBlockers.summarize(list, now: now, ownPID: 42).isEmpty)
    }
}
