import AVFoundation

/// Records a call to one compressed audio file: the denoised mic stream and
/// the others' stream summed into 48 kHz mono AAC (~0.7 MB/min — an hour-long
/// meeting stays under 50 MB). Writes stream to disk as the call happens;
/// nothing is buffered beyond a few hundred milliseconds.
///
/// The two feeds arrive on the two engines' processing queues; everything
/// hops onto the recorder's own serial queue, so the audio paths never block
/// on disk I/O.
public final class CallRecorder {
    public let url: URL

    private let queue = DispatchQueue(label: "ode.call.recorder", qos: .utility)
    private var file: AVAudioFile?
    private var micPending: [Float] = []
    private var othersPending: [Float] = []
    private var framesWritten: Int = 0

    /// Backlog on one side past which the other is assumed absent (speaker
    /// path off, one-sided call) and padded with silence — a lone stream must
    /// still record. Half a second also absorbs the paths' scheduling skew.
    static let stallSlack = 24_000  // 0.5 s at 48 kHz
    /// Hard cap per FIFO; beyond this something upstream is wrong and
    /// dropping oldest audio beats unbounded memory growth.
    static let maxPending = 48_000 * 10

    /// Opens the file immediately; throws if the container can't be created.
    public init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioIO.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Feed the processed mic stream (48 kHz mono). Safe from any thread.
    public func feedMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.file != nil else { return }
            self.append(samples, to: &self.micPending)
            self.flush(force: false)
        }
    }

    /// Feed the processed others'-audio stream (48 kHz mono). Any thread.
    public func feedOthers(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.file != nil else { return }
            self.append(samples, to: &self.othersPending)
            self.flush(force: false)
        }
    }

    /// Flush the tail, finalize the container, and stop accepting audio.
    /// Returns the file URL, or nil if no audio was ever written (the empty
    /// file is removed).
    public func finish() -> URL? {
        queue.sync {
            flush(force: true)
            file = nil  // AVAudioFile finalizes on release
        }
        if framesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // MARK: - Queue-only internals

    private func append(_ samples: [Float], to fifo: inout [Float]) {
        fifo.append(contentsOf: samples)
        if fifo.count > Self.maxPending {
            fifo.removeFirst(fifo.count - Self.maxPending)
        }
    }

    /// Mix and write whatever both sides agree on. When one side lags by more
    /// than the stall slack (or on the final flush), the short side is padded
    /// with silence so a one-sided call still produces audio.
    private func flush(force: Bool) {
        let longer = max(micPending.count, othersPending.count)
        let shorter = min(micPending.count, othersPending.count)
        if force || longer - shorter > Self.stallSlack {
            let pad = longer - micPending.count
            if pad > 0 { micPending.append(contentsOf: repeatElement(0, count: pad)) }
            let padO = longer - othersPending.count
            if padO > 0 { othersPending.append(contentsOf: repeatElement(0, count: padO)) }
        }
        let n = min(micPending.count, othersPending.count)
        guard n > 0, let file else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioIO.monoFormat,
                                            frameCapacity: AVAudioFrameCount(n)),
              let channel = buffer.floatChannelData?[0] else { return }
        for i in 0..<n {
            channel[i] = max(-1, min(1, micPending[i] + othersPending[i]))
        }
        buffer.frameLength = AVAudioFrameCount(n)
        micPending.removeFirst(n)
        othersPending.removeFirst(n)
        do {
            try file.write(from: buffer)
            framesWritten += n
        } catch {
            LiveEngine.diagnostic("[recorder] write failed: \(error.localizedDescription)")
            self.file = nil  // stop trying; the partial file still finalizes
        }
    }
}
