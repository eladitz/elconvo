// The once-a-month "enjoying it?" prompt and the Ko-fi link.
//
// Asks only after a few successful conversions. "Yes" leads to a donation offer; donating
// (or saying you already have) pauses the question for a year, anything else for a month.

import AppKit

@MainActor
enum Donation {
    static let page = URL(string: "https://ko-fi.com/eladitzkin")!

    private static let defaults = UserDefaults.standard
    private static let nextAskKey = "nextDonationAsk"
    private static let usesKey = "successfulConversions"
    private static let month: TimeInterval = 30 * 24 * 3600
    private static let year: TimeInterval = 365 * 24 * 3600

    static func start() {
        if defaults.object(forKey: nextAskKey) == nil { snooze(month) }
        // Elconvo runs for weeks without relaunching, so look again a few times a day.
        let timer = Timer(timeInterval: 4 * 3600, repeats: true) { _ in MainActor.assumeIsolated { askIfDue() } }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { askIfDue() }
    }

    static func recordUse() {
        defaults.set(defaults.integer(forKey: usesKey) + 1, forKey: usesKey)
    }

    static func askIfDue() {
        guard let next = defaults.object(forKey: nextAskKey) as? Date, Date() >= next,
              defaults.integer(forKey: usesKey) >= 3,
              NSEvent.pressedMouseButtons == 0   // never in the middle of a drag
        else { return }
        ask()
    }

    static func ask() {
        NSApp.activate(ignoringOtherApps: true)

        let like = NSAlert()
        like.messageText = "Enjoying Elconvo?"
        like.informativeText = "You've converted \(defaults.integer(forKey: usesKey)) files with it so far."
        like.addButton(withTitle: "Yes, I like it")
        like.addButton(withTitle: "Not really")
        guard like.runModal() == .alertFirstButtonReturn else { snooze(month); return }

        let give = NSAlert()
        give.messageText = "Glad to hear it!"
        give.informativeText = "Elconvo is free and made by one person. If it saves you time, a small donation on Ko-fi helps keep it going."
        give.addButton(withTitle: "Donate on Ko-fi")
        give.addButton(withTitle: "Maybe Later")
        give.addButton(withTitle: "I've Already Donated")
        switch give.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(page)
            snooze(year)
        case .alertThirdButtonReturn:
            snooze(year)
        default:
            snooze(month)
        }
    }

    private static func snooze(_ interval: TimeInterval) {
        defaults.set(Date().addingTimeInterval(interval), forKey: nextAskKey)
    }
}
