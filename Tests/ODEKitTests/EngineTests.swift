import XCTest
import AVFoundation
import CoreAudio
@testable import ODEKit

final class LiveEngineTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // LiveEngine owns a Denoiser; point the locator at the repo model.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = repoRoot.appendingPathComponent("Resources/dpdfnet2_48khz_hr.onnx")
        setenv("ODE_MODEL_PATH", model.path, 1)
    }

    func testBypassDenoiseIsThreadSafeProperty() {
        let engine = LiveEngine()
        XCTAssertFalse(engine.bypassDenoise)
        engine.bypassDenoise = true
        XCTAssertTrue(engine.bypassDenoise)
        engine.bypassDenoise = false
        XCTAssertFalse(engine.bypassDenoise)
    }

    func testInitialStateIsIdle() {
        let engine = LiveEngine()
        XCTAssertEqual(engine.currentLevel, 0)
        XCTAssertFalse(engine.isHealthy)
    }

    func testStopBeforeStartIsANoOp() {
        let engine = LiveEngine()
        engine.stop()          // must not crash or corrupt state
        engine.stop()
        XCTAssertFalse(engine.isHealthy)
    }

    func testOnCapturedAudioLockedAccess() {
        let engine = LiveEngine()
        XCTAssertNil(engine.onCapturedAudio)
        engine.onCapturedAudio = { _ in }
        XCTAssertNotNil(engine.onCapturedAudio)
        engine.onCapturedAudio = nil
        XCTAssertNil(engine.onCapturedAudio)
    }

    func testStartRefusesSameInputAndOutputDevice() {
        let engine = LiveEngine()
        guard let out = AudioDevices.defaultOutput() else { return }
        // Same device on both ends must throw (feedback loop guard) before
        // any audio hardware is touched.
        XCTAssertThrowsError(try engine.start(inputDevice: out, outputDevice: out))
        XCTAssertFalse(engine.isHealthy)
    }
}

@available(macOS 26.0, *)
final class StreamTranscriberLifecycleTests: XCTestCase {
    func testAppendBeforeStartIsIgnored() {
        let t = StreamTranscriber()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        buf.frameLength = 480
        t.append(buf)          // no session yet — must be a no-op
    }

    func testFinishBeforeStartIsSafe() async {
        let t = StreamTranscriber()
        await t.finish()       // nothing to flush — must not hang or crash
    }

    func testCustomLocaleInit() {
        _ = StreamTranscriber(locale: Locale(identifier: "es_MX"))
    }
}

final class AudioDevicesUsageTests: XCTestCase {
    func testUsageQueriesReturnForRealDevice() {
        guard let out = AudioDevices.defaultOutput() else { return }
        // Values depend on what's playing; the calls must simply not fail.
        _ = AudioDevices.isOutputInUse(out.id)
        _ = AudioDevices.isInputInUse(out.id)
    }

    func testUsageObserverInstallAndRemove() {
        guard let out = AudioDevices.defaultOutput() else { return }
        let obs = AudioDevices.addUsageObserver(out.id,
                                                readScope: kAudioObjectPropertyScopeOutput) { _ in }
        XCTAssertNotNil(obs)
        if let obs { AudioDevices.removeUsageObserver(obs) }
    }

    func testHardwareObserverInstallAndRemove() {
        let obs = AudioDevices.addHardwareObserver(kAudioHardwarePropertyDevices) {}
        XCTAssertNotNil(obs)
        if let obs { AudioDevices.removeHardwareObserver(obs) }
    }

    func testSetVisibleOnUnknownUIDFails() {
        XCTAssertFalse(AudioDevices.setVisible(true, uid: "not-a-real-uid"))
    }

    func testDefaultInputHasInputChannels() {
        // Built-in mic exists on any Mac running these tests.
        if let inp = AudioDevices.defaultInput() {
            XCTAssertTrue(inp.hasInput)
            XCTAssertFalse(inp.uid.isEmpty)
        }
    }
}

final class MeetingAIAvailabilityTests: XCTestCase {
    func testAvailabilityAndMessageAreConsistent() {
        guard #available(macOS 26.0, *) else { return }
        if MeetingAI.isAvailable {
            XCTAssertNil(MeetingAI.availabilityMessage())
        } else {
            XCTAssertNotNil(MeetingAI.availabilityMessage())
        }
    }

    func testAIErrorDescription() {
        guard #available(macOS 26.0, *) else { return }
        let err = MeetingAI.AIError.unavailable("Model missing")
        XCTAssertEqual(err.errorDescription, "Model missing")
    }
}
