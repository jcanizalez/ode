import Foundation

/// Field-diagnostics support: caring for the engine log and bundling
/// everything needed to debug a remote machine into one shareable zip.
/// The bundle contains logs, crash reports and a system snapshot —
/// never audio, recordings or transcripts.
public enum Diagnostics {
    /// The log LiveEngine.diagnostic appends to.
    public static var engineLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ODE/engine-stats.log")
    }

    /// Where exported bundles land (app support — no TCC prompts, revealed
    /// in Finder for the user to share).
    public static var exportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ODE/Diagnostics", isDirectory: true)
    }

    /// Cap the engine log so long-lived installs don't grow it unbounded:
    /// past `capBytes`, the oldest lines are dropped and only the newest
    /// `keepBytes` remain. Call once at launch.
    public static func trimEngineLog(capBytes: Int = 2_000_000, keepBytes: Int = 1_000_000) {
        trimLog(at: engineLogURL, capBytes: capBytes, keepBytes: keepBytes)
    }

    public static func trimLog(at url: URL, capBytes: Int, keepBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > capBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(keepBytes)
        // Start at a line boundary so the first kept line isn't garbled.
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: nl))
        }
        try? tail.write(to: url, options: .atomic)
    }

    /// Assemble a diagnostics zip: engine log, the newest ODE crash
    /// reports, model-cache state, the audio device list, ODE's settings
    /// and a system snapshot. Returns the zip's location.
    public static func exportBundle(appVersion: String) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ODE-diagnostics-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        if fm.fileExists(atPath: engineLogURL.path) {
            try? fm.copyItem(at: engineLogURL,
                             to: staging.appendingPathComponent("engine-stats.log"))
        }

        // The 5 newest ODE crash reports. macOS moves older reports into
        // Retired/ after a few days — a "keeps crashing" investigation
        // needs those too.
        let reportsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let mine = [reportsDir, reportsDir.appendingPathComponent("Retired")]
            .compactMap { try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .joined()
            .filter { $0.lastPathComponent.hasPrefix("ODE-") && $0.pathExtension == "ips" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // name embeds the date
            .prefix(5)
        for report in mine {
            try? fm.copyItem(at: report,
                             to: staging.appendingPathComponent(report.lastPathComponent))
        }

        try systemSnapshot(appVersion: appVersion)
            .write(to: staging.appendingPathComponent("system-info.txt"),
                   atomically: true, encoding: .utf8)

        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let zip = exportDirectory.appendingPathComponent("ODE-diagnostics-\(stamp).zip")
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "ode.diagnostics", code: Int(ditto.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the zip archive."])
        }
        return zip
    }

    private static func systemSnapshot(appVersion: String) -> String {
        var lines: [String] = []
        lines.append("ODE \(appVersion)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("hardware: \(hardwareModel()) (\(machineArch()))")
        lines.append("exported: \(ISO8601DateFormatter().string(from: Date()))")

        lines.append("")
        lines.append("== models ==")
        lines.append("parakeet cached: \(ParakeetStreamTranscriber.modelIsCached)")
        lines.append("diarizer cached: \(SpeakerDiarizer.modelIsCached)")
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) {
            lines.append("model cache (\(modelsDir.path)): \(names.sorted().joined(separator: ", "))")
        } else {
            lines.append("model cache: empty (nothing downloaded yet)")
        }

        lines.append("")
        lines.append("== audio devices ==")
        for dev in AudioDevices.all() {
            lines.append("\(dev.name) [id \(dev.id)]"
                         + (dev.hasInput ? " in" : "") + (dev.hasOutput ? " out" : ""))
        }

        lines.append("")
        lines.append("== settings (ode.*) ==")
        let defaults = UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("ode.") }
            .sorted { $0.key < $1.key }
        for (key, value) in defaults {
            lines.append("\(key) = \(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func machineArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
