import AppKit

/// Best-effort guess of which app is running the call. CoreAudio doesn't
/// expose which process opened a HAL device, but the usage observer fires the
/// moment a call app opens the ODE device — so at that instant the app is
/// running and almost certainly frontmost.
enum SourceAppDetector {
    private static let conferencingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "net.whatsapp.WhatsApp": "WhatsApp",
    ]
    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
    ]

    static func detect() -> String? {
        let ids = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // A dedicated conferencing app beats a browser; frontmost breaks ties.
        let hits = ids.compactMap { conferencingApps[$0] }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            if let front, let name = conferencingApps[front] { return name }
            return hits[0]
        }
        // Only browsers → likely a Meet-style web call; trust frontmost only.
        if let front, let name = browsers[front] { return name }
        return nil
    }
}
