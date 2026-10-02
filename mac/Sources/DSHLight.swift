/**
 * DSHLight — the renderer for the dsh-status light.
 *
 * Reads the state document published by the dsh-status plugin and draws a
 * traffic light: red for a feed that cannot be trusted, yellow while a session
 * works or is blocked on you, green for a finish you have not read, and dark
 * when there is nothing to say. A double-click switches between DSH and the
 * application you came from; a right-click opens the list.
 *
 * Two modes, one state machine:
 *   DSHLight --print [--state-file PATH]   follow the light in a terminal
 *   DSHLight [--state-file PATH]           draw it above every window
 *
 * The contract is documented in ../README.md. Nothing here writes to the state
 * file, so the renderer cannot disturb the publisher.
 */
import Cocoa
import Darwin

// MARK: - The contract

/// What the light can show.
///
/// Three of these are states the publisher reports; `broken` is not — it is the
/// renderer saying *the feed itself* cannot be trusted (no file, unreadable,
/// stale). Keeping "I cannot tell" apart from "nothing is happening" is the
/// whole point: a session switch is rest, not an alarm.
enum Light: String {
    case idle
    case working
    case waiting
    /// The agent is blocked on the user: a permission or a question.
    case asking
    case broken

    /// Fold a published `state` onto a light. Anything unrecognised becomes
    /// `idle`, never `broken`, so adding a state later can never make an older
    /// renderer cry wolf — and a legacy `unknown` from an older publisher reads
    /// as rest rather than as failure.
    init(published: String) {
        switch published {
        case "working": self = .working
        case "waiting": self = .waiting
        case "asking": self = .asking
        default: self = .idle
        }
    }
}

/// How many heartbeats may pass before the feed is called dead.
private let staleAfterHeartbeats = 3.0
private let fallbackHeartbeatMs = 2000.0
private let defaultStatePath =
    ("~/Library/Application Support/dsh-status/state.json" as NSString).expandingTildeInPath

/// One session, as the publisher reports it. Kept whole rather than reduced to
/// the headline because only the renderer knows what the user has already read.
struct SessionSummary {
    var id: String
    var state: Light
    var changedAt: Date?
}

/// One currency's figures, as the publisher reports them.
///
/// Kept as the strings the provider sent: `"14.58"` is the figure a user checks
/// against their invoice, and a double would render 14.580000000000002.
struct AccountFigures {
    var currency: String
    var total: String
}

/// The account block, when the publisher sends one.
///
/// Every field is optional because there are three things this can be: figures,
/// a reason there are none, or nothing at all from a publisher that predates it.
/// None of it reaches the lenses: the light answers for the agent, not for the
/// account, so a refused key is a dim row in a list rather than a red lens.
struct Account {
    var fetchedAt: Date?
    var intervalMs: Double?
    var isAvailable: Bool?
    /// A code, never the provider's message: that message quotes the key.
    var reason: String?
    var figures: [AccountFigures] = []
}

struct Reading {
    var light: Light
    /// Why this light: the publisher's `reason`, or why we could not trust it.
    /// Deliberately free of volatile numbers — see `signature`.
    var detail: String
    var sessionId: String?
    /// Seconds since the publisher last wrote. `nil` when there is no file.
    var age: Double?
    /// When this state was last *asserted*. This, not `updatedAt`, is what an
    /// acknowledgement may be compared against: it survives the heartbeat.
    var changedAt: Date?
    /// The heartbeat expired: the last state is no longer a claim about now.
    var stale = false
    /// Every session the publisher is watching, when it reports them.
    /// Empty for a publisher that predates the snapshot.
    var sessions: [SessionSummary] = []
    /// The account, when the publisher reports one. Shown in the list only.
    var account: Account?

    /// The feed is unusable, however readable it was.
    static func broken(_ detail: String) -> Reading {
        Reading(light: .broken, detail: detail, sessionId: nil, age: nil)
    }

    /// What counts as a change worth reporting. The age is excluded on purpose:
    /// it grows every tick, and a follower that reported it would reprint the
    /// same line forever instead of going quiet until something happens.
    var signature: String { "\(light.rawValue)|\(detail)" }

    var symbol: String {
        switch light {
        case .idle: return "⚪"
        case .working: return "🟡"
        case .waiting: return "🟢"
        case .asking: return "🔵"
        case .broken: return "🔴"
        }
    }

    var label: String {
        switch light {
        case .idle: return "idle"
        case .working: return "working"
        case .waiting: return "waiting"
        case .asking: return "asking"
        case .broken: return "no signal"
        }
    }
}

enum StateFile {
    /// Read one document. Every failure resolves to `unknown` rather than
    /// throwing: a renderer must be able to draw "I cannot tell" as red.
    static func read(at path: String, now: Date = Date()) -> Reading {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .broken("no file")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return .broken("unreadable")
        }

        let heartbeatMs = (object["heartbeatMs"] as? NSNumber)?.doubleValue ?? fallbackHeartbeatMs
        let updatedAtMs = (object["updatedAt"] as? NSNumber)?.doubleValue
        let changedAtMs = (object["changedAt"] as? NSNumber)?.doubleValue
        let reason = object["reason"] as? String ?? "-"
        let sessionId = object["sessionId"] as? String

        guard let updatedAtMs else {
            return .broken("no timestamp")
        }

        let age = now.timeIntervalSince1970 - updatedAtMs / 1000
        let staleAfter = max(staleAfterHeartbeats, staleAfterHeartbeats * heartbeatMs / 1000)

        // Read the meta once, for both the sessions and the account: a stale
        // feed still carries the last figures it was given, and they are worth
        // showing next to how old they are.
        var sessions: [SessionSummary] = []
        var account: Account?
        if let meta = object["meta"] as? [String: Any] {
            if let reported = meta["sessions"] as? [[String: Any]] {
                sessions = reported.compactMap { item in
                    guard let id = item["id"] as? String, let state = item["state"] as? String else {
                        return nil
                    }
                    let changedAt = (item["changedAt"] as? NSNumber)
                        .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                    return SessionSummary(id: id, state: Light(published: state), changedAt: changedAt)
                }
            }
            account = parseAccount(from: meta["account"])
        }

        if age > staleAfter {
            // A killed DSH must not leave a light on: the heartbeat is gone,
            // so the last state is no longer a claim about right now. The
            // detail stays free of the live age so the signature is stable.
            return Reading(
                light: .broken,
                detail: String(format: "stale (heartbeat %.1fs)", heartbeatMs / 1000),
                sessionId: sessionId,
                age: age,
                stale: true,
                sessions: sessions,
                account: account
            )
        }

        // An unrecognised value is rest, not failure: the feed is healthy and
        // simply says something this build has not learned yet.
        let light = Light(published: object["state"] as? String ?? "")
        return Reading(
            light: light,
            detail: reason,
            sessionId: sessionId,
            age: age,
            changedAt: changedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            sessions: sessions,
            account: account
        )
    }

    /// A string field, accepting a number as well: the publisher sends strings,
    /// and a JSON number would otherwise read as a missing figure.
    private static func text(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return nil
    }

    /// The account block, read defensively: an unreadable currency is dropped
    /// rather than failing the whole document, because a feed the user can still
    /// see the light from must never be thrown away over a figure.
    private static func parseAccount(from value: Any?) -> Account? {
        guard let reported = value as? [String: Any] else { return nil }
        let reported_figures = reported["balances"] as? [[String: Any]] ?? []
        let figures = reported_figures.compactMap { item -> AccountFigures? in
            guard let currency = text(item, "currency"), let total = text(item, "total") else {
                return nil
            }
            return AccountFigures(currency: currency, total: total)
        }
        return Account(
            fetchedAt: (reported["fetchedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            intervalMs: (reported["intervalMs"] as? NSNumber)?.doubleValue,
            isAvailable: reported["isAvailable"] as? Bool,
            reason: reported["reason"] as? String,
            figures: figures
        )
    }
}

// MARK: - Acknowledgement

enum TargetApp {
    /// The bundle identifier of an installed application, read from its own
    /// Info.plist so nothing here hard-codes an identity that could change.
    static func bundleIdentifier(of appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let object = plist as? [String: Any] else { return nil }
        return object["CFBundleIdentifier"] as? String
    }
}

/// Whether the user has come back to DSH since the last finish.
///
/// Green is a reminder; once the user is looking at DSH again the reminder has
/// been served, and the light rests. Only the Mac can know this — the harness
/// has no notion of which window is in front — so the acknowledgement lives
/// here and the state file is left alone.
///
/// Two ways to acknowledge, because both mean "I am back":
///   - the frontmost application *becomes* DSH (switching back to it), and
///   - clicking the light, which is a deliberate "take me there".
///
/// The same poll also remembers the last application that was *not* DSH, so a
/// click on a resting light can put the user back where they were. One watcher
/// for both, because it is the same observation — who is in front right now.
final class Acknowledgement {
    private static let storedKey = "DSHLight.acknowledgedAt"

    private let targets: Set<String>
    private(set) var at: Date?
    /// The last application seen in front that was neither DSH nor the light.
    private var lastObservedFrontmost: String?
    /// The last application the user was in that was not DSH. Restoring the
    /// application is as far as public API reaches — macOS will not let one
    /// application select another's window or browser tab — but it is what
    /// "back to my work" means: VSCode returns to the window being edited, the
    /// browser to the tab being read.
    private(set) var lastOther: (bundleId: String, url: URL)?

    init(targets: Set<String>, fallbackAppPath: String) {
        var resolved = targets
        if resolved.isEmpty, let identifier = TargetApp.bundleIdentifier(of: fallbackAppPath) {
            resolved = [identifier]
        }
        self.targets = resolved
        let stored = UserDefaults.standard.double(forKey: Acknowledgement.storedKey)
        if stored > 0 { self.at = Date(timeIntervalSince1970: stored) }
        // Whatever is in front now is the first thing poll() will see, so a user
        // who is already in DSH settles the light on the very first tick.
        self.lastObservedFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var targetDescription: String {
        targets.isEmpty ? "none — acknowledgement is off" : targets.sorted().joined(separator: ", ")
    }

    /// Note a return to DSH. Returns true only on the transition, so a user who
    /// stays in DSH does not keep re-acknowledging.
    /// Note where the user is. Looking at DSH *is* having read whatever is
    /// waiting — the reminder exists to bring them here, so while they are here
    /// it has nothing left to do. This also covers what a transition cannot see:
    /// a turn that finishes while the user is already in DSH.
    func poll() {
        let front = NSWorkspace.shared.frontmostApplication
        let identifier = front?.bundleIdentifier

        // Our own application is never recorded: clicking the light can make it
        // frontmost, and that must not be mistaken for "the user is looking at
        // DSH" — or for somewhere to return to.
        guard let identifier, identifier != Bundle.main.bundleIdentifier else { return }
        lastObservedFrontmost = identifier

        if targets.contains(identifier) {
            acknowledge()
            return
        }

        // Remember where the user was, so a click can put them back. DSH itself
        // is never remembered: returning to it would be a no-op.
        if let url = front?.bundleURL {
            lastOther = (identifier, url)
        }
    }

    /// Whether the last *real* application in front was DSH.
    ///
    /// Deliberately the last observation rather than a fresh read. Clicking the
    /// light can make its own process frontmost, and asking "who is in front
    /// now" at that moment answers "the light" — which turned every return click
    /// into a forward one, so the light could never send the user back.
    var isLookingAtTarget: Bool {
        guard let observed = lastObservedFrontmost else { return false }
        return targets.contains(observed)
    }

    /// Put the user back in the application they were in before DSH.
    @discardableResult
    func returnToLastOther() -> Bool {
        guard let lastOther else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: lastOther.url, configuration: configuration)
        return true
    }

    func acknowledge() {
        let now = Date()
        let previous = at
        at = now
        // While the user stays in DSH this refreshes every tick, and writing the
        // defaults plist four times a second buys nothing: the in-memory value is
        // what the light reads, and the stored one only has to survive a restart
        // roughly as recent.
        if previous == nil || now.timeIntervalSince(previous!) > 5 {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Acknowledgement.storedKey)
        }
    }

    /// True when this finish happened before the user came back.
    func covers(_ publishedAt: Date?) -> Bool {
        guard let at, let publishedAt else { return false }
        return at >= publishedAt
    }
}

/// The same reading with a different light and reason.
private func shown(_ reading: Reading, as light: Light, why detail: String) -> Reading {
    var changed = reading
    changed.light = light
    changed.detail = detail
    return changed
}

/// Watches for the moment a finish appears.
///
/// Needed for a publisher that predates `changedAt`, whose only timestamp is the
/// heartbeat's. The reader then has to notice the transition itself. A heartbeat
/// rewrites the file without changing the state, reason or session, so the
/// identity below stays put and the observed moment does not drift.
final class FinishTracker {
    private var identity: String?
    private var observedAt: Date?

    /// When the current finish appeared, as far as this reader can tell.
    func note(_ reading: Reading) -> Date? {
        let current = "\(reading.light.rawValue)|\(reading.detail)|\(reading.sessionId ?? "-")"
        if current != identity {
            identity = current
            observedAt = reading.light == .waiting ? Date() : nil
        }
        return observedAt
    }
}

/// What to draw, once the acknowledgement is taken into account. A finish the
/// user has already returned to is rest, not a reminder — but a *newer* finish
/// is green again, because the acknowledgement is older than it.
///
/// The comparison is against when the state was *asserted*, never against
/// `updatedAt`: the heartbeat moves that one every couple of seconds, and an
/// acknowledgement measured against it expires on the very next beat.
func displayed(
    _ reading: Reading,
    acknowledgedBy acknowledgement: Acknowledgement?,
    finishObservedAt: Date?
) -> Reading {
    guard reading.light != .broken else { return reading }

    // Several sessions can be live at once, and the publisher reports all of
    // them. The aggregation happens here because an acknowledgement is a fact
    // about the viewer and only this side has it. Most urgent first:
    //   - a session blocked on the user outranks everything: it cannot proceed;
    //   - a finish the user has not read is green, *even while other sessions
    //     work* — otherwise unrelated work would swallow the finish;
    //   - any remaining work is yellow;
    //   - otherwise the light rests.
    // That is what makes "one finished, one still working" show green, and then
    // yellow rather than grey once the user has come back and read the finish.
    if !reading.sessions.isEmpty {
        if reading.sessions.contains(where: { $0.state == .asking }) {
            return shown(reading, as: .asking, why: "blocked on you")
        }
        let unread = reading.sessions.filter { session in
            guard session.state == .waiting else { return false }
            let stamp = session.changedAt ?? reading.changedAt ?? finishObservedAt
            return acknowledgement?.covers(stamp) != true
        }
        if !unread.isEmpty {
            return shown(
                reading,
                as: .waiting,
                why: unread.count == 1 ? "finished, unread" : "\(unread.count) finished, unread"
            )
        }
        let working = reading.sessions.filter { $0.state == .working }.count
        if working > 0 {
            return shown(reading, as: .working, why: working == 1 ? "working" : "\(working) working")
        }
        return shown(reading, as: .idle, why: "rest")
    }

    guard reading.light == .waiting else { return reading }
    guard let finishAt = reading.changedAt ?? finishObservedAt else { return reading }
    guard acknowledgement?.covers(finishAt) == true else { return reading }
    return shown(reading, as: .idle, why: "\(reading.detail) · back in dsh")
}

// MARK: - Options

struct Options {
    var statePath = defaultStatePath
    var printMode = false
    var openTarget = "/Applications/DSH Desktop.app"
    var level: NSWindow.Level = .screenSaver
    /// Lens size for this run, overriding the size slider. The sliders are the
    /// normal way to set this; the flag is for a script that wants one shape.
    var lens: CGFloat?
    var interval = 0.25
    /// Bundle identifiers whose return to the front acknowledges a finish.
    var ackTargets: Set<String> = []
    /// Set by --no-ack: green is kept until the publisher says otherwise.
    var ackDisabled = false

    static let usage = """
    DSHLight — a traffic light for DeepSeek Harness.

      DSHLight --print [--state-file PATH] [--interval SECONDS]
          Follow the light in this terminal: print it now, then again on every
          change. Ctrl-C to stop.

      DSHLight [--state-file PATH] [--open APP] [--ack-app BUNDLE-ID] [--no-ack]
               [--level LEVEL] [--size POINTS]
          Draw the light above every window, on every Space, over fullscreen
          apps. It is a traffic light: three lenses stacked, red at the top. It
          docks to the nearest side of the screen when you drop it, and slides
          up and down that side until you drop it again.
          DOUBLE-CLICK switches between DSH and the application you came from,
          whatever is lit. RIGHT-CLICK opens the list. Dragging docks it
          elsewhere, and a single click does nothing on purpose.
          LEVEL is floating, status or screensaver (default screensaver).
          The list holds one slider each for the size of a lens, the gap
          between them, and how solid a resting and a lit lens are. Every
          slider applies as it is dragged and is remembered afterwards.
          --size POINTS overrides the size slider for this run only.

          A finish rests as soon as DSH is in front: you are looking at it, so
          the reminder has done its job. A session blocked on you pulses the
          yellow lens between a third and full solidity rather than blinking.
          --ack-app adds another application whose return counts; repeat it for
          several. The default is the application named by --open. --no-ack keeps
          green until the next prompt instead.

      DSHLight --help
    """

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func value() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--print":
                options.printMode = true
            case "--state-file":
                if let path = value() { options.statePath = (path as NSString).expandingTildeInPath }
            case "--open":
                if let path = value() { options.openTarget = (path as NSString).expandingTildeInPath }
            case "--interval":
                if let raw = value(), let seconds = Double(raw), seconds > 0 { options.interval = seconds }
            case "--size":
                if let raw = value(), let points = Double(raw) { options.lens = CGFloat(points) }
            case "--ack-app":
                if let identifier = value() { options.ackTargets.insert(identifier) }
            case "--no-ack":
                options.ackTargets = []
                options.ackDisabled = true
            case "--level":
                switch value() {
                case "floating": options.level = .floating
                case "status": options.level = .statusBar
                default: options.level = .screenSaver
                }
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                FileHandle.standardError.write("DSHLight: ignoring \"\(argument)\"\n".data(using: .utf8)!)
            }
            index += 1
        }
        return options
    }
}

// MARK: - Print mode

/// Whether stdout is a terminal, so colour is only emitted where it is read.
private var stdoutIsTerminal: Bool { isatty(STDOUT_FILENO) == 1 }

private func coloured(_ text: String, _ light: Light) -> String {
    guard stdoutIsTerminal else { return text }
    let code: String
    switch light {
    case .idle: code = "90"  // grey
    case .working: code = "33"  // yellow
    case .waiting: code = "32"  // green
    case .asking: code = "34"  // blue
    case .broken: code = "31"  // red
    }
    return "\u{001B}[\(code)m\(text)\u{001B}[0m"
}

private func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

/// Print the light now, then again whenever it changes. Never exits on its own.
///
/// "Changes" means the light or its stable reason — not the clock. A follower
/// that reprinted on every tick would bury the one transition it exists to show.
func runPrintMode(_ options: Options) {
    let acknowledgement = options.ackDisabled
        ? nil
        : Acknowledgement(targets: options.ackTargets, fallbackAppPath: options.openTarget)
    print("watching \(options.statePath)")
    if let acknowledgement {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        print("resting when these come to the front: \(acknowledgement.targetDescription)")
        print("frontmost now: \(front)")
    }
    let finishes = FinishTracker()
    var previous: String?
    var announcedReturn: String?
    while true {
        acknowledgement?.poll()
        // What a click would do right now, so the rule is visible without
        // clicking — and so this can be checked without a mouse.
        let from = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nowhere"
        let to: String
        if acknowledgement?.isLookingAtTarget == true {
            to = acknowledgement?.lastOther?.bundleId ?? "nowhere (no other app seen yet)"
        } else {
            to = acknowledgement.map { _ in "dsh" } ?? "dsh (acknowledgement off)"
        }
        let clickLine = "[double-click: \(from) -> \(to)]"
        if clickLine != announcedReturn {
            announcedReturn = clickLine
            print("  \(clickLine)")
        }
        let raw = StateFile.read(at: options.statePath)
        let reading = displayed(raw, acknowledgedBy: acknowledgement, finishObservedAt: finishes.note(raw))
        if reading.signature != previous {
            previous = reading.signature
            var line = "\(reading.label) · \(reading.detail)"
            if reading.stale, let age = reading.age {
                line += String(format: " · no write for %.1fs", age)
            }
            let suffix = reading.sessionId.map { "  \($0)" } ?? ""
            print("\(stamp())  \(coloured(reading.symbol, reading.light))  \(line)\(suffix)")
            // Flush so a piped reader sees the light as it changes.
            fflush(stdout)
        }
        // Pump the run loop instead of sleeping. NSWorkspace reports the
        // frontmost application through a notification delivered on this loop,
        // so a plain sleep never processes it and the process keeps seeing
        // whatever was in front when it started.
        RunLoop.current.run(until: Date().addingTimeInterval(options.interval))
    }
}

// MARK: - Window mode

// MARK: - Appearance

/// Everything about the light the user can dial in, in one place.
///
/// There is no style to choose any more: there is one light, and the four
/// numbers below are the sliders in the right-click list. They persist, so the
/// light comes back the way it was left, and they are the only thing the
/// window size, the drawing and the snapping have to agree about.
struct Look {
    var lens: CGFloat
    var gap: CGFloat
    /// How solid an unlit lens is.
    var restAlpha: Double
    /// How solid the lit lens is, before the pulse on top of it.
    var litAlpha: Double

    static let lensRange: ClosedRange<Double> = 12...48
    static let gapRange: ClosedRange<Double> = 0...24
    static let restRange: ClosedRange<Double> = 0.04...0.60
    static let litRange: ClosedRange<Double> = 0.20...1.00

    /// What a fresh install wears, and the fallback for a remembered value that
    /// is missing or unreadable: the numbers the light was dialled to by hand.
    /// The body's opacity and the corner radius have no slider — see
    /// `bodyOpacity`.
    static let standard = Look(lens: 20, gap: 8, restAlpha: 0.28, litAlpha: 0.85)

    /// The housing is proportional rather than a setting: a fixed inset looks
    /// like a collar around a small lens and like a hairline around a large one.
    var padding: CGFloat {
        min(14, max(6, (lens * 0.32).rounded()))
    }

    /// The light is a traffic light: three lenses stacked, red at the top. It
    /// has one shape, and that shape is the only thing the window size, the
    /// drawing and the snapping have to agree about.
    var size: NSSize {
        let lenses = 3
        let length = CGFloat(lenses) * lens + CGFloat(lenses - 1) * gap + 2 * padding
        let breadth = lens + 2 * padding
        return NSSize(width: breadth, height: length)
    }

    /// The body's corner radius, taken from the **narrow** side so a tall light
    /// gets a rounded square rather than a lozenge: at 32 points wide, a radius
    /// of 14 leaves four points of straight edge.
    var cornerRadius: CGFloat {
        min(14, min(size.width, size.height) * 0.32)
    }
}

/// One slider of the list, declared as a case so that its label, its range, its
/// readout and the place its value goes are each written once. A fifth control
/// is then one case rather than a fifth copy of the same row.
enum LookField: String, CaseIterable {
    case size, gap, rest, lit

    var title: String {
        switch self {
        case .size: return "Size"
        case .gap: return "Gap"
        case .rest: return "Rest"
        case .lit: return "Lit"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .size: return Look.lensRange
        case .gap: return Look.gapRange
        case .rest: return Look.restRange
        case .lit: return Look.litRange
        }
    }

    /// Whole points for the two spacings, whole percents for the two opacities.
    var step: Double {
        switch self {
        case .size, .gap: return 1
        case .rest, .lit: return 0.01
        }
    }

    func value(of look: Look) -> Double {
        switch self {
        case .size: return Double(look.lens)
        case .gap: return Double(look.gap)
        case .rest: return look.restAlpha
        case .lit: return look.litAlpha
        }
    }

    func set(_ value: Double, on look: inout Look) {
        switch self {
        case .size: look.lens = CGFloat(value)
        case .gap: look.gap = CGFloat(value)
        case .rest: look.restAlpha = value
        case .lit: look.litAlpha = value
        }
    }

    func readout(_ value: Double) -> String {
        switch self {
        case .size, .gap: return "\(Int(value.rounded())) pt"
        case .rest, .lit: return "\(Int((value * 100).rounded()))%"
        }
    }
}

/// Which side of the screen the light is docked to. Remembered, because the list
/// is placed flush to the same one.
///
/// There is no top and bottom, and no orientation to go with them. A traffic
/// light is a vertical object: three lenses stacked, red at the top. Laying them
/// in a row along the top edge made a shape that had to be re-fitted every time
/// the menu bar moved, which is one problem that only existed because the shape
/// did.
enum ScreenSide: String {
    case left, right
}

/// One lens of the three, in the order a traffic light and an Apple window
/// button pair both use: stop, wait, go.
enum Lens {
    case red, yellow, green
}

final class TrafficLightView: NSView {
    var reading = Reading.broken("starting") {
        didSet {
            updateBreathing()
            needsDisplay = true
        }
    }
    var look = Look.standard {
        didSet { needsDisplay = true }
    }

    var onTap: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onMenu: (() -> Void)?

    private var originAtDragStart: NSPoint?
    private var mouseAtDragStart: NSPoint?
    private var dragged = false
    /// Read on mouse-down, where AppKit sets it reliably. Two clicks on purpose:
    /// one stray click must not move the user.
    private var clicksAtMouseDown = 1
    /// When the first of the two clicks landed, so the light can show it arrived.
    private var pendingUntil: Date?

    /// The ring around a lens: how light it is, and how solid. The opacity is not
    /// a dial — it was chosen with the old black ring and is left exactly where it
    /// was, so only the colour of the edge changed.
    private static let rimGrey: CGFloat = 0.45
    private static let rimAlpha: CGFloat = 0.45

    /// A quick pulse rather than a slow breath: a session blocked on the user is
    /// the one state that has to be noticed from across the room. It never goes
    /// dark — the two ends are **alphas**, not fractions of the Lit slider, because
    /// what a lens must never fall below is a brightness in its own right.
    private static let breathPeriod: Double = 1.0
    /// The dim end of the pulse: a third solid.
    private static let breathFloor: Double = 0.3
    /// What a pulsing lens peaks at, whatever the Lit slider says: fully solid.
    private static let breathPeak: Double = 1.0
    private var breathEpoch = Date()
    private var breathTimer: Timer?

    deinit {
        breathTimer?.invalidate()
    }

    private var needsBreathing: Bool {
        reading.light == .asking
    }

    /// A redraw clock that runs only while something is pulsing.
    private func updateBreathing() {
        if needsBreathing, breathTimer == nil {
            breathEpoch = Date()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.current.add(timer, forMode: .common)
            breathTimer = timer
        } else if !needsBreathing, let timer = breathTimer {
            timer.invalidate()
            breathTimer = nil
        }
    }

    /// How far into the pulse we are: 0 at the trough, 1 at the crest. A lens
    /// that is not pulsing sits at 1 — full solidity, nothing animating.
    private func level(for lens: Lens) -> Double {
        guard lens == .yellow, needsBreathing else { return 1 }
        let phase = Date().timeIntervalSince(breathEpoch)
            .truncatingRemainder(dividingBy: Self.breathPeriod) / Self.breathPeriod
        return 0.5 + 0.5 * sin(2 * .pi * phase)
    }

    /// The alpha of a lit lens at this instant.
    ///
    /// A lens that is not pulsing is the Lit slider. A pulsing one sweeps
    /// between `breathFloor` and the brighter of the Lit slider and `breathPeak`:
    /// a slider set above the peak raises it, and the floor follows only if the
    /// slider is set below the floor.
    private func solidity(of lens: Lens, level: Double) -> Double {
        guard lens == .yellow, needsBreathing else { return Double(look.litAlpha) }
        let peak = max(Double(look.litAlpha), Self.breathPeak)
        let floor = min(Self.breathFloor, peak)
        return floor + (peak - floor) * level
    }

    /// Which lens is lit, if any. Rest is every lens dark, which is what a real
    /// traffic light with nothing to say looks like.
    private func litLens() -> Lens? {
        switch reading.light {
        case .broken: return .red
        case .asking, .working: return .yellow
        case .waiting: return .green
        case .idle: return nil
        }
    }

    private func colour(of lens: Lens) -> NSColor {
        switch lens {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        }
    }

    /// Lenses in fixed order, stacked from the top: red, then yellow, then
    /// green, which is the order a traffic light has used for a century.
    private func lensRects() -> [(Lens, NSRect)] {
        let lens = look.lens
        let padding = look.padding
        let step = lens + look.gap
        return [Lens.red, .yellow, .green].enumerated().map { index, lensOfLight in
            let distance = CGFloat(index) * step
            let rect = NSRect(
                x: padding,
                y: bounds.height - padding - lens - distance,
                width: lens,
                height: lens
            )
            return (lensOfLight, rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = litLens()

        for (lens, rect) in lensRects() {
            let isLit = lens == lit
            draw(lens: lens, in: rect, lit: isLit, level: isLit ? level(for: lens) : 0)
        }

        if let until = pendingUntil, Date() < until {
            // A rounded square, not a ring: at this size a circle reads as part
            // of the light, and the acknowledgement should not look like one.
            let box = bounds.insetBy(dx: 1.5, dy: 1.5)
            let radius = min(12, box.height * 0.28)
            let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func draw(lens: Lens, in rect: NSRect, lit: Bool, level: Double) {
        let colour = colour(of: lens)
        if lit {
            colour.withAlphaComponent(CGFloat(solidity(of: lens, level: level))).setFill()
        } else {
            // A resting lens is dark glass, not a hole: visible enough that the
            // traffic light still reads as one when nothing is lit. Its solidity
            // is the Rest slider.
            colour.withAlphaComponent(CGFloat(look.restAlpha)).setFill()
        }
        NSBezierPath(ovalIn: rect).fill()

        // A flat disc with a ring, and nothing else. The white highlight that
        // used to sit in the upper left made the lenses read as glass, and it was
        // asked for and then asked away: at this size it was the busiest thing on
        // the screen, and a traffic light is not a lens.
        //
        // The ring is a light grey, not black, at an opacity that is deliberately
        // unchanged at 0.45: black at this size drew a hard edge that the eye went
        // to before the lens it was outlining.
        NSColor(white: Self.rimGrey, alpha: Self.rimAlpha).setStroke()
        let rim = NSBezierPath(ovalIn: rect)
        rim.lineWidth = 1
        rim.stroke()
    }

    /// AppKit uses the first click on an inactive window *only* to activate it
    /// and never delivers it, which would cost every gesture one extra click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Manual drag so that a click and a drag can share one small target.
    override func mouseDown(with event: NSEvent) {
        originAtDragStart = window?.frame.origin
        mouseAtDragStart = NSEvent.mouseLocation
        dragged = false
        clicksAtMouseDown = event.clickCount
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = originAtDragStart, let start = mouseAtDragStart else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if hypot(dx, dy) > 3 { dragged = true }
        window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            originAtDragStart = nil
            mouseAtDragStart = nil
        }
        if dragged {
            if let origin = window?.frame.origin { onMove?(origin) }
        } else if clicksAtMouseDown >= 2 {
            pendingUntil = nil
            needsDisplay = true
            onTap?()
        } else {
            // First click: show that it arrived, then forget it.
            pendingUntil = Date().addingTimeInterval(0.7)
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var window: NSWindow?
    private var view: TrafficLightView?
    private var backdrop: NSVisualEffectView?
    /// The wash that darkens the body, kept so its corners follow a resize.
    private var shade: NSView?
    private var timer: Timer?
    private let finishes = FinishTracker()
    private var look = Look.standard
    private var side: ScreenSide = .right
    /// The last reading, kept whole so the list can show the account: the view
    /// only needs the colour, but the account rides in the same document.
    private var reading: Reading = .broken("starting")
    /// How far the light sits from the side it is docked to.
    private static let dockInset: CGFloat = 10
    /// How solid the grey body behind the lenses is, against the material's own
    /// full strength: half of it, so the body reads as a hint of a shape rather
    /// than as a panel with a light standing in it. There is no slider for this
    /// one — it is the closest thing the light has to a fixed piece of its look.
    private static let bodyOpacity: CGFloat = 0.5

    /// How much black is washed over that material.
    ///
    /// The material is a *light* grey in light appearance, which read as too
    /// bright against a bright wallpaper in the middle of the day. Darkening it
    /// rather than turning the body's opacity down again is deliberate: a fainter
    /// body dissolves into whatever is behind it, while a darker one keeps its
    /// shape and reads as a body in both appearances.
    private static let bodyShade: CGFloat = 0.15
    /// The platform's top-up page: the same destination DSH's own account service
    /// publishes for this (`/top_up` against the platform origin), so the list is
    /// not inventing a URL that could drift from the product's.
    private static let topUpURL = URL(string: "https://platform.deepseek.com/top_up")

    /// How far above the point passed to `popUp` the top of the list lands.
    ///
    /// Measured, not documented: a menu is placed by its top-left corner, and
    /// this one puts its top five points higher than the point given, on every
    /// menu height and at every anchor tried. It used to pass unnoticed because
    /// the light outranked the list and swallowed the overlap; now that the list
    /// is drawn over the light, five points is the difference between flush and
    /// a light with its edge sliced off.
    private static let menuTopBias: CGFloat = 5
    private lazy var acknowledgement: Acknowledgement? = options.ackDisabled
        ? nil
        : Acknowledgement(targets: options.ackTargets, fallbackAppPath: options.openTarget)

    private static let originKey = "DSHLight.windowOrigin"
    private static let lookKey = "DSHLight.look"
    /// Where the docked side is remembered. Named for a border because it used
    /// to hold four of them; a stale "top" or "bottom" simply fails to parse and
    /// the side is decided from where the light is, as it always was.
    private static let sideKey = "DSHLight.border"

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        look = loadLook(defaults: defaults)
        if let wanted = options.lens {
            look.lens = min(max(wanted, CGFloat(Look.lensRange.lowerBound)),
                            CGFloat(Look.lensRange.upperBound)).rounded()
        }
        side = ScreenSide(rawValue: defaults.string(forKey: Self.sideKey) ?? "") ?? .right

        let size = look.size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = options.level
        // Every Space, unmoved by Mission Control, and visible over another
        // application's fullscreen window: this is what "everywhere" needs.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false

        // The body is the same material a menu uses, so the right-click list
        // reads as an extension of the light instead of a separate object. It
        // also gives the light a faint grey body on any wallpaper, and follows
        // light and dark appearance on its own.
        //
        // The body and the light are **siblings, not parent and child**. They
        // were nested until the body needed to be fainter than opaque, and a
        // view's alpha applies to everything inside it: the lenses would have
        // faded along with the square behind them. A plain container holds both,
        // and the body is faded on its own.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.alphaValue = Self.bodyOpacity
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = look.cornerRadius
        backdrop.layer?.masksToBounds = true

        let shade = NSView(frame: NSRect(origin: .zero, size: size))
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.bodyShade).cgColor
        shade.layer?.cornerRadius = look.cornerRadius
        shade.layer?.masksToBounds = true
        shade.autoresizingMask = [.width, .height]

        let view = TrafficLightView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        view.look = look
        view.onTap = { [weak self] in self?.navigate() }
        view.onMove = { [weak self] _ in self?.dock() }
        view.onMenu = { [weak self] in self?.showMenu() }
        container.addSubview(backdrop)
        container.addSubview(shade)
        container.addSubview(view)
        window.contentView = container

        window.setFrameOrigin(restoredOrigin(size: size))
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        self.backdrop = backdrop
        self.shade = shade
        dock()

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The screen the light is on.
    private func screen(of window: NSWindow) -> NSScreen? {
        window.screen ?? NSScreen.main
    }

    private func refresh() {
        guard let view else { return }
        acknowledgement?.poll()
        let raw = StateFile.read(at: options.statePath)
        let next = displayed(raw, acknowledgedBy: acknowledgement, finishObservedAt: finishes.note(raw))
        // Kept whether or not the colour moved: the account can change while the
        // light stays exactly as it is, and the list is built on demand.
        reading = next
        // Redraw only when the colour actually changes: the light is idle most
        // of the time, and the reading itself changes every heartbeat tick.
        if next.light != view.reading.light {
            view.reading = next
        }
    }

    /// A double-click means "take me to what needs me, then put me back": the
    /// colour answers whether to go, the gesture only does the going.
    private func navigate() {
        if acknowledgement?.isLookingAtTarget == true {
            acknowledgement?.returnToLastOther()
        } else {
            bringHarnessForward()
        }
    }

    private func bringHarnessForward() {
        let url = URL(fileURLWithPath: options.openTarget)
        if !NSWorkspace.shared.open(url) {
            FileHandle.standardError.write("DSHLight: cannot open \(options.openTarget)\n".data(using: .utf8)!)
        }
    }

    // MARK: Docking

    /// Flush to whichever side of its screen is nearest, and remember which,
    /// because the list is placed against the same one.
    ///
    /// There is nothing else to decide. The light has one shape, so a change of
    /// side cannot resize it, and the up-and-down position along the side is
    /// whatever the user dropped it at.
    private func dock() {
        guard let window, let screen = screen(of: window) else { return }
        let visible = usableFrame(of: screen)
        side = sideToAdopt(for: window.frame, in: visible)
        let want = look.size

        // Grow inward from the side it is heading to, so a change of size never
        // throws the light across the screen.
        var frame = window.frame
        if frame.size != want {
            switch side {
            case .right: frame.origin.x = frame.maxX - want.width
            case .left: frame.origin.x = frame.minX
            }
            frame.size = want
            window.setFrame(frame, display: true)
        }

        let origin = dockedOrigin(size: want, in: visible, from: window.frame.origin)
        window.setFrameOrigin(origin)

        // The rounded body has to follow the size the sliders give it: a radius
        // tuned for one shape is a circle on a small light and a square on a
        // large one.
        view?.look = look
        backdrop?.layer?.cornerRadius = look.cornerRadius
        shade?.layer?.cornerRadius = look.cornerRadius

        UserDefaults.standard.set(side.rawValue, forKey: Self.sideKey)
        UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
    }

    /// The docked origin for the side the light is on: flush to that side, at
    /// whatever height it was dropped.
    private func dockedOrigin(size want: NSSize, in visible: NSRect, from current: NSPoint) -> NSPoint {
        var origin = current
        switch side {
        case .left: origin.x = visible.minX + Self.dockInset
        case .right: origin.x = visible.maxX - want.width - Self.dockInset
        }
        // A last guarantee that no change can park the light off the screen, or
        // under the menu bar: the bar only ever covers the top strip, and a
        // vertical light is free to sit anywhere below it.
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - want.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - want.height))
        return origin
    }

    /// Where a window may sit on a screen: its visible frame, less the menu bar.
    ///
    /// The bar is reserved at its own height, always, and that is the end of it.
    /// It cannot be measured to the point: with "automatically hide and show the
    /// menu bar" on, `visibleFrame` reports the whole screen with the bar up and
    /// with it down — measured, 1680x1050 against a 1680x1050 frame in both
    /// states — and reading the bar's own window instead means following it at
    /// video rate, which is a laggy light that overlaps the bar it is following.
    /// A vertical light on a side edge has no business in the top strip anyway,
    /// so the strip is simply held back and the light can never be underneath.
    private func usableFrame(of screen: NSScreen) -> NSRect {
        var frame = screen.visibleFrame
        let menuBar = max(NSStatusBar.system.thickness, screen.frame.maxY - frame.maxY)
        let alreadyReserved = screen.frame.maxY - frame.maxY
        if alreadyReserved < menuBar {
            frame.size.height = max(0, frame.height - (menuBar - alreadyReserved))
        }
        return frame
    }

    /// The side a drop should adopt: whichever of the two is nearer.
    ///
    /// This carried a corner rule for a while, because a drop near a corner
    /// could flip the light between a row and a stack and the flip resized it
    /// half off the screen. One shape means the nearest side is the whole
    /// answer.
    private func sideToAdopt(for frame: NSRect, in visible: NSRect) -> ScreenSide {
        let toLeft = abs(frame.minX - visible.minX)
        let toRight = abs(visible.maxX - frame.maxX)
        return toLeft <= toRight ? .left : .right
    }

    /// Restore the last position, clamped onto a screen that still exists — a
    /// display that went away must not strand the light off-screen.
    private func restoredOrigin(size: NSSize) -> NSPoint {
        guard let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double],
              saved.count == 2 else {
            return defaultOrigin(size: size)
        }
        let candidate = NSRect(x: saved[0], y: saved[1], width: size.width, height: size.height)
        let visible = NSScreen.screens.contains { usableFrame(of: $0).intersects(candidate) }
        return visible ? candidate.origin : defaultOrigin(size: size)
    }

    /// Top-right of the main screen's visible frame, clear of the menu bar.
    private func defaultOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 40, y: 40) }
        let frame = usableFrame(of: screen)
        return NSPoint(
            x: frame.maxX - size.width - Self.dockInset,
            y: frame.maxY - size.height - Self.dockInset
        )
    }

    // MARK: Menu

    /// The list hangs inward from the side the light is docked to, so a docked
    /// light never opens a list off the edge of the screen: to the right of a
    /// light on the left edge, to the left of one on the right.
    ///
    /// Placement is worked out as the list's own top-left corner — `left` and
    /// `top` below — and only converted to the point `popUp` wants at the end,
    /// because that point is not the corner: the window lands `menuTopBias`
    /// points higher.
    private func showMenu() {
        guard let window else { return }
        let menu = buildMenu()
        let frame = window.frame
        let width = menu.size.width
        let height = menu.size.height

        var left: CGFloat
        var top: CGFloat
        switch side {
        case .right: left = frame.minX - width; top = frame.maxY
        case .left: left = frame.maxX; top = frame.maxY
        }

        // And keep the whole list on the screen it was opened from.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let margin: CGFloat = 4
        left = min(max(left, visible.minX + margin), max(visible.minX + margin, visible.maxX - width - margin))
        top = min(max(top, visible.minY + height + margin), max(visible.minY + height + margin, visible.maxY - margin))
        let point = NSPoint(x: left, y: top - Self.menuTopBias)

        // The light's window outranks a menu on purpose, so while the list is
        // open it steps down. Otherwise the list — and the sliders in it — would
        // be drawn under the very window they are changing, and a lens growing
        // across a row would take the clicks meant for it.
        let level = window.level
        window.level = .floating
        menu.popUp(positioning: nil, at: point, in: nil)
        window.level = level
        window.orderFrontRegardless()
    }

    /// The list is a list of lists. Almost everything worth putting in it is a
    /// thing with several numbers inside, and a folded group keeps the first
    /// level down to what the light can actually say at a glance.
    ///
    /// One separator, not two: AppKit collapses consecutive separators when it
    /// draws, but counts every one of them in `menu.size`, and the placement of
    /// the list is worked out from that number.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(folded("Appearance", appearanceMenu()))
        menu.addItem(folded("Account", accountMenu()))

        menu.addItem(.separator())
        menu.addItem(choice("Quit the light", on: false, action: #selector(quit), tag: 0))
        return menu
    }

    /// One row per slider, in one column, so every row is the same width and a
    /// future control is one more row. The values are whatever the light is
    /// wearing now, which is also what a folded group leaves behind.
    private func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for field in LookField.allCases {
            let row = SliderRow(field: field, value: field.value(of: look))
            row.onChange = { [weak self] value in
                self?.applyLook { field.set(value, on: &$0) }
            }
            let item = NSMenuItem()
            item.view = row
            item.isEnabled = true
            menu.addItem(item)
        }
        // A way back. Four sliders with no undo is a one-way door, and the
        // numbers that are the default are not something anyone should have to
        // remember — they are what a fresh install wears.
        menu.addItem(.separator())
        menu.addItem(choice("Reset to default", on: false, action: #selector(resetLook), tag: 0))
        return menu
    }

    /// Put the light back to what a fresh install wears.
    ///
    /// It is one assignment through the same path a slider uses, so the window is
    /// re-fitted, the change is remembered, and there is no second way for the
    /// look to be set that could drift from the first.
    @objc private func resetLook() {
        applyLook { $0 = Look.standard }
    }

    /// An account list. The figures come from the publisher's `meta.account`,
    /// which is the only place they can come from: this process holds no key and
    /// makes no requests, so a balance it cannot read is a dim row naming the
    /// reason rather than a number it guessed.
    ///
    /// One line per currency the account actually holds something in — the
    /// endpoint answers in every currency the account has ever touched, and a
    /// currency sitting at zero is a line that says nothing. Then the way to add
    /// to it, and a footer saying how old the answer is, because hours-old
    /// figures should not read like current ones. Nothing here can change a lens.
    private func accountMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let account = reading.account else {
            menu.addItem(note("no source wired up yet"))
            return menu
        }
        let held = account.figures.filter { !isZero($0.total) }
        for figures in held {
            // The figure on its own line, titled by its currency. A balance is
            // one number: folding it behind its own name put the answer a click
            // deeper than the question, and the breakdown it unfolded into —
            // granted, topped up — is a page's business rather than a light's.
            let item = NSMenuItem()
            item.view = ValueRow(label: figures.currency, value: figures.total)
            item.isEnabled = true
            menu.addItem(item)
        }
        if held.isEmpty, !account.figures.isEmpty {
            menu.addItem(note("every balance is zero"))
        }
        if let reason = account.reason {
            menu.addItem(note(reasonText(reason)))
        }
        if account.isAvailable == false {
            menu.addItem(note("not enough balance for api calls"))
        }
        menu.addItem(.separator())
        menu.addItem(topUp())
        menu.addItem(note(freshness(account)))
        return menu
    }

    /// The row that opens the platform's own top-up page.
    ///
    /// The destination is not invented here: DSH's account service publishes
    /// exactly this link for exactly this purpose — `/top_up` against the
    /// platform origin. It is offered whether or not the balance is readable,
    /// because "I cannot read your balance" is no reason to leave someone with no
    /// way to add to it.
    private func topUp() -> NSMenuItem {
        let item = NSMenuItem(title: "Top up now", action: #selector(openTopUp), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openTopUp() {
        guard let url = Self.topUpURL else { return }
        if !NSWorkspace.shared.open(url) {
            FileHandle.standardError.write("DSHLight: cannot open \(url)\n".data(using: .utf8)!)
        }
    }

    /// Whether a figure the provider sent is zero, however it was written:
    /// `"0"`, `"0.00"`, `"0.000000"`. A figure that cannot be read is **not**
    /// treated as zero — an amount we cannot parse is shown rather than hidden.
    private func isZero(_ figure: String) -> Bool {
        guard let amount = Decimal(string: figure, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return amount == 0
    }

    /// A row that is only information: dim, and not clickable.
    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The publisher's codes in words. It sends codes rather than the provider's
    /// message, because that message quotes the key it refused.
    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "no-key": return "no api key configured"
        case "unauthorized": return "deepseek refused the key"
        case "offline": return "could not reach deepseek"
        case "timeout": return "deepseek did not answer"
        case "no-fetch": return "this runtime cannot fetch"
        case "bad-body": return "unreadable answer"
        default:
            return reason.hasPrefix("http-") ? "deepseek error \(reason.dropFirst(5))" : reason
        }
    }

    /// How old the figures are, and whether that is too old to trust.
    private func freshness(_ account: Account) -> String {
        guard let fetchedAt = account.fetchedAt else { return "never fetched" }
        let age = max(0, Date().timeIntervalSince(fetchedAt))
        let when = age < 90 ? "just now" : "\(relative(age)) ago"
        let interval = (account.intervalMs ?? 300_000) / 1000
        // Three missed lookups is not a slow network, it is a stopped publisher.
        return age > interval * 3 ? "updated \(when) — stale" : "updated \(when)"
    }

    /// "4m", "2h 5m". Short, because it sits in a menu row.
    private func relative(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// A group that is closed until it is opened, which is what a submenu is.
    private func folded(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    // MARK: The look

    /// The remembered numbers, with anything missing or out of range falling
    /// back to the standard: a half-written or older set of values can never
    /// produce a light this build cannot draw.
    private func loadLook(defaults: UserDefaults) -> Look {
        guard let saved = defaults.dictionary(forKey: Self.lookKey) else { return .standard }
        func number(_ key: String) -> Double? { (saved[key] as? NSNumber)?.doubleValue }
        func clamped(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.map { min(max($0, range.lowerBound), range.upperBound) }
        }
        var look = Look.standard
        if let value = clamped(number("lens"), Look.lensRange) { look.lens = CGFloat(value.rounded()) }
        if let value = clamped(number("gap"), Look.gapRange) { look.gap = CGFloat(value.rounded()) }
        if let value = clamped(number("rest"), Look.restRange) { look.restAlpha = value }
        if let value = clamped(number("lit"), Look.litRange) { look.litAlpha = value }
        return look
    }

    private func saveLook() {
        store(look)
    }

    private func store(_ look: Look, in defaults: UserDefaults = .standard) {
        defaults.set([
            "lens": Double(look.lens),
            "gap": Double(look.gap),
            "rest": look.restAlpha,
            "lit": look.litAlpha
        ], forKey: Self.lookKey)
    }

    /// A slider is a live control, so the light on screen is the preview: every
    /// step re-fits and re-anchors the window rather than waiting for the list
    /// to close. `dock()` is the one place that knows how, which is why a change
    /// of size and a change of opacity take the same path.
    private func applyLook(_ change: (inout Look) -> Void) {
        change(&look)
        saveLook()
        dock()
        window?.displayIfNeeded()
    }

    private func choice(_ title: String, on: Bool, action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.tag = tag
        return item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}

// MARK: - The list's rows

/// One labelled slider, as a row of the list.
///
/// The list is an `NSMenu`, and a menu item is allowed to carry a view, so a row
/// is a small view with a slider in it. Every row is built the same way and the
/// longest of them sets the width, which is what keeps the list a single column
/// of equal widths.
final class SliderRow: NSView {
    static let width: CGFloat = 236
    static let height: CGFloat = 30

    private let field: LookField
    private let name = NSTextField(labelWithString: "")
    private let readout = NSTextField(labelWithString: "")
    private let slider = MiniSlider()

    /// Called on every step of a drag, with an already-stepped value.
    var onChange: ((Double) -> Void)?

    init(field: LookField, value: Double) {
        self.field = field
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        name.stringValue = field.title
        name.font = .menuFont(ofSize: 0)
        name.textColor = .labelColor
        name.frame = NSRect(x: 14, y: 7, width: 40, height: 16)
        name.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]

        // Digits all one width, so the number does not shuffle sideways as it
        // changes under the drag.
        readout.stringValue = field.readout(value)
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.frame = NSRect(x: 178, y: 7, width: 44, height: 16)
        readout.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]

        slider.range = field.range
        slider.step = field.step
        slider.value = value
        slider.frame = NSRect(x: 62, y: 5, width: 112, height: 20)
        slider.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        slider.onDrag = { [weak self] value in
            guard let self else { return }
            self.readout.stringValue = self.field.readout(value)
            self.onChange?(value)
        }

        addSubview(name)
        addSubview(slider)
        addSubview(readout)
        // A menu may be wider than its widest view; the slider takes the slack.
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }
}

/// A label with a figure on the right, as a row of the list.
///
/// Deliberately the same geometry as `SliderRow` — same left inset, same right
/// edge for the value — so a list of figures and a list of sliders line up when
/// they are next to each other.
final class ValueRow: NSView {
    static let width: CGFloat = SliderRow.width

    private let name: NSTextField
    private let figure = NSTextField(labelWithString: "")

    init(label: String, value: String) {
        name = NSTextField(labelWithString: label)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))

        name.font = .menuFont(ofSize: 0)
        name.textColor = .labelColor
        name.frame = NSRect(x: 14, y: 5, width: 140, height: 16)
        name.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]

        figure.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        figure.textColor = .secondaryLabelColor
        figure.alignment = .right
        figure.frame = NSRect(x: Self.width - 14 - 80, y: 5, width: 80, height: 16)
        figure.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        figure.stringValue = value

        addSubview(name)
        addSubview(figure)
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }
}

/// A slider, drawn and tracked here rather than taken from AppKit.
///
/// The one event a menu is documented to push into a view it hosts is the mouse:
/// `mouseDown:`, `mouseDragged:` and `mouseUp:`. A stock `NSSlider` pulls its own
/// drags out of the event queue instead, and a control that never starts its own
/// tracking loop cannot be left half working. This one follows the mouse the way
/// the menu delivers it and reports every step, which is what makes the light
/// track the knob rather than catch up when it is let go.
final class MiniSlider: NSView {
    var range: ClosedRange<Double> = 0...100
    /// The granularity a drag snaps to: whole points for a size or a gap, whole
    /// percents for an opacity. A slider that cannot reach a value the readout
    /// can print is a slider that lies.
    var step: Double = 1
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }
    /// Every step of a drag, and the click that starts one.
    var onDrag: ((Double) -> Void)?

    private static let trackHeight: CGFloat = 4
    private static let knobRadius: CGFloat = 6.5

    /// The track stops one knob-radius short of each end, so the knob is never
    /// half outside the row it belongs to.
    private var usable: NSRect { bounds.insetBy(dx: Self.knobRadius, dy: 0) }

    private func fraction(of value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let usable = self.usable
        let radius = Self.trackHeight / 2
        let track = NSRect(
            x: usable.minX,
            y: bounds.midY - Self.trackHeight / 2,
            width: usable.width,
            height: Self.trackHeight
        )
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        // The travelled part is grey, not the accent colour: this light has no
        // blue anywhere in it, and a blue bar under a traffic light would be the
        // loudest thing on the screen.
        let travelled = NSRect(
            x: track.minX,
            y: track.minY,
            width: track.width * fraction(of: value),
            height: track.height
        )
        if travelled.width > 0 {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: travelled, xRadius: radius, yRadius: radius).fill()
        }

        let knob = NSRect(
            x: track.minX + track.width * fraction(of: value) - Self.knobRadius,
            y: bounds.midY - Self.knobRadius,
            width: Self.knobRadius * 2,
            height: Self.knobRadius * 2
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let rim = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        rim.lineWidth = 1
        rim.stroke()
    }

    /// The list can be open while this application is not the active one, and
    /// the first click in a window is normally spent on activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { follow(event) }
    override func mouseDragged(with event: NSEvent) { follow(event) }
    override func mouseUp(with event: NSEvent) { follow(event) }

    /// Put the knob where the mouse is and report it, on the way in and on every
    /// step of the drag: the light has to move while the knob does.
    private func follow(_ event: NSEvent) {
        let usable = self.usable
        guard usable.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let along = Double(min(max((point.x - usable.minX) / usable.width, 0), 1))
        let wanted = range.lowerBound + along * (range.upperBound - range.lowerBound)
        value = min(max((wanted / step).rounded() * step, range.lowerBound), range.upperBound)
        onDrag?(value)
    }
}

/// What the singleton lock came to.
private enum LockResult {
    /// This process holds it.
    case held(Int32)
    /// It could not even be opened. That is not contention, so the light runs
    /// anyway — refusing to draw would be worse than a possible duplicate.
    case unavailable(String)
    /// Another light holds it.
    case busy
}

/// An advisory lock held for the life of the process.
///
/// One light only: the plugin launches one on every boot, and a hand-launched
/// one would otherwise draw a second traffic light over the first. `flock` is
/// released by the kernel when the process dies, so a crash cannot strand the
/// lock — which is why it is a lock rather than a pid file.
private func acquireSingletonLock() -> LockResult {
    let directory = ("~/Library/Application Support/dsh-status" as NSString).expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = (directory as NSString).appendingPathComponent("light.lock")
    let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else {
        return .unavailable(String(cString: strerror(errno)))
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        close(descriptor)
        return .busy
    }
    return .held(descriptor)
}

func runWindowMode(_ options: Options) {
    switch acquireSingletonLock() {
    case .busy:
        FileHandle.standardError.write("DSHLight: another light is already running\n".data(using: .utf8)!)
        exit(0)
    case .unavailable(let reason):
        // The descriptor stays open for the life of the process; the lock is
        // released by the kernel, so there is nothing to close on purpose.
        FileHandle.standardError.write("DSHLight: no lock (\(reason)); running without one\n".data(using: .utf8)!)
    case .held:
        break
    }

    let application = NSApplication.shared
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    // Accessory: no Dock icon, no menu bar of our own.
    application.setActivationPolicy(.accessory)
    application.run()
}

// MARK: - Entry

let options = Options.parse(CommandLine.arguments)
if options.printMode {
    runPrintMode(options)
} else {
    runWindowMode(options)
}
