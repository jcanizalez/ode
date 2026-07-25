import XCTest
import CoreAudio
@testable import ODEKit

/// Capture liveness: the rules that decide a mic has gone dead mid-call.
/// Before these existed, a raw AUHAL unit whose device vanished kept
/// reporting `isRunning == true` for the rest of the call, so nothing —
/// not `LiveEngine.isHealthy`, not the controller's zombie watchdog —
/// could see it. The clock is injected, so none of this sleeps.
final class CaptureLivenessTests: XCTestCase {

    // MARK: - Delivery deadline

    func testFreshlyStampedWatchIsNotStalled() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        XCTAssertFalse(live.isStalled(at: 1_000))
        XCTAssertEqual(live.silence(at: 1_000), 0)
    }

    func testNotStalledWhileWithinTheDeadline() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        // Just inside 2 s: a real IO gap is ~10 ms, but scheduling jitter
        // must never be mistaken for a dead device.
        XCTAssertFalse(live.isStalled(at: 1_001.9))
        XCTAssertEqual(live.silence(at: 1_001.9), 1.9, accuracy: 0.0001)
    }

    func testStalledOnceTheDeadlinePasses() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        XCTAssertTrue(live.isStalled(at: 1_002.1))
    }

    func testEachDeliveryPushesTheDeadlineOut() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        live.stamp(at: 1_001.5)
        // Would have stalled at 1002.1 without the second buffer.
        XCTAssertFalse(live.isStalled(at: 1_003.0))
        XCTAssertTrue(live.isStalled(at: 1_003.6))
    }

    func testDeadlineIsOverridableForCallersThatWantOne() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        XCTAssertTrue(live.isStalled(at: 1_000.5, deadline: 0.25))
        XCTAssertFalse(live.isStalled(at: 1_000.5, deadline: 5))
    }

    /// `start()` stamps before starting the unit, so the deadline runs from
    /// the start rather than from the first buffer — a unit that starts
    /// clean and never delivers anything is a failure ODE has actually hit.
    func testNeverStampedWatchReadsAsStalled() {
        let live = CaptureLiveness()
        XCTAssertTrue(live.isStalled(at: 1_000))
    }

    // MARK: - Drop counting

    func testCleanSessionHasNothingToReport() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        XCTAssertEqual(live.renderFailures, 0)
        XCTAssertEqual(live.allocFailures, 0)
        XCTAssertNil(live.takeUnreportedDrops())
    }

    func testRenderFailuresAccumulateAndKeepTheLastStatus() {
        var live = CaptureLiveness()
        live.noteRenderFailure(-10863)
        live.noteRenderFailure(-10874)
        XCTAssertEqual(live.renderFailures, 2)
        XCTAssertEqual(live.lastRenderStatus, -10874)
    }

    func testAllocFailuresCountSeparately() {
        var live = CaptureLiveness()
        live.noteAllocFailure()
        live.noteAllocFailure()
        XCTAssertEqual(live.allocFailures, 2)
        XCTAssertEqual(live.renderFailures, 0)
        XCTAssertEqual(live.lastRenderStatus, noErr)
    }

    func testDropsAreReportedExactlyOnce() {
        var live = CaptureLiveness()
        live.noteRenderFailure(-10863)
        guard let first = live.takeUnreportedDrops() else {
            return XCTFail("first poll must yield the drops to log")
        }
        XCTAssertEqual(first.render, 1)
        XCTAssertEqual(first.status, -10863)
        // The watchdog polls once a second for the life of the call; it must
        // not reprint this line on every tick.
        XCTAssertNil(live.takeUnreportedDrops())
        live.noteRenderFailure(-10863)
        XCTAssertNil(live.takeUnreportedDrops())
    }

    /// An allocation failure is a dropped buffer too — it must not stay
    /// invisible just because `AudioUnitRender` was never reached.
    func testAllocFailureAloneStillReports() {
        var live = CaptureLiveness()
        live.noteAllocFailure()
        guard let drops = live.takeUnreportedDrops() else {
            return XCTFail("alloc drops must be reported")
        }
        XCTAssertEqual(drops.alloc, 1)
        XCTAssertEqual(drops.render, 0)
    }

    func testReportCarriesBothCounters() {
        var live = CaptureLiveness()
        live.noteRenderFailure(-1)
        live.noteAllocFailure()
        live.noteAllocFailure()
        let drops = live.takeUnreportedDrops()
        XCTAssertEqual(drops?.render, 1)
        XCTAssertEqual(drops?.alloc, 2)
    }

    /// Counting must not disturb the delivery clock: a session can be
    /// dropping buffers and still be delivering others.
    func testCountingDropsDoesNotTouchTheDeliveryClock() {
        var live = CaptureLiveness()
        live.stamp(at: 1_000)
        live.noteRenderFailure(-1)
        live.noteAllocFailure()
        XCTAssertEqual(live.silence(at: 1_000.5), 0.5, accuracy: 0.0001)
    }
}

/// The HAL queries behind capture setup, against device IDs that cannot
/// exist. These are the paths that must fail honestly rather than hand back
/// a plausible-looking format for the wrong device.
final class HALCaptureTests: XCTestCase {

    func testHardwareInputFormatIsNilForAnUnknownDevice() {
        XCTAssertNil(HALCapture.hardwareInputFormat(deviceID: AudioDeviceID(0)))
        XCTAssertNil(HALCapture.hardwareInputFormat(deviceID: AudioDeviceID(999_999)))
    }

    func testConstructionThrowsForAnUnknownDevice() {
        // No unit must survive a bogus device: a half-built AUHAL that
        // reports success is exactly how capture used to die silently.
        XCTAssertThrowsError(try HALCapture(deviceID: AudioDeviceID(999_999)))
    }
}
