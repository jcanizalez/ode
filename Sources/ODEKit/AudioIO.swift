import AVFoundation

public enum AudioIO {
    public static let sampleRate: Double = 48_000

    /// 48 kHz mono float format used throughout the engine.
    public static var monoFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    // MARK: - WAV reading

    /// Reads any audio file and returns mono Float samples resampled to 48 kHz.
    public static func readSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: frameCount) else {
            throw IOError.alloc
        }
        try file.read(into: srcBuffer)
        return resampleToMono48k(srcBuffer)
    }

    /// Convert an arbitrary PCM buffer to a flat array of 48 kHz mono floats.
    public static func resampleToMono48k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let dstFormat = monoFormat
        if buffer.format == dstFormat {
            return bufferToArray(buffer)
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: dstFormat) else {
            return bufferToArray(buffer)
        }
        let ratio = dstFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else {
            return bufferToArray(buffer)
        }
        var fed = false
        let status = converter.convert(to: dst, error: nil) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        _ = status
        return bufferToArray(dst)
    }

    public static func bufferToArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    // MARK: - WAV writing

    /// Writes mono 48 kHz float samples to a 16-bit PCM WAV file.
    public static func writeWav(samples: [Float], url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 48_000
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                             frameCapacity: AVAudioFrameCount(n)) else {
                throw IOError.alloc
            }
            buf.frameLength = AVAudioFrameCount(n)
            let dst = buf.floatChannelData![0]
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!.advanced(by: i), count: n)
            }
            try file.write(from: buf)
            i += n
        }
    }

    enum IOError: Error { case alloc }
}
