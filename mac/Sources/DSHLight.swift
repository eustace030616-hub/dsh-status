/**
 * DSHLight — stage 2 of the DSH status light.
 *
 * Reads the state document published by the dsh-status plugin and draws one
 * dot: red for unknown or stale, yellow while the agent works, green when the
 * turn is over and it is the user's move. Clicking brings DSH forward.
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

/// What the dot can show.
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

struct Reading {
    var light: Light
    /// Why this light: the publisher's `reason`, or why we could not trust it.
    /// Deliberately free of volatile numbers — see `signature`.
    var detail: String
    var sessionId: String?
    /// Seconds since the publisher last wrote. `nil` when there is no file.
    var age: Double?
    /// When that write happened. Only useful for staleness — the heartbeat
    /// moves it every couple of seconds.
    var publishedAt: Date?
    /// When this state was last *asserted*. This, not `updatedAt`, is what an
    /// acknowledgement may be compared against: it survives the heartbeat.
    var changedAt: Date?
    /// The heartbeat expired: the last state is no longer a claim about now.
    var stale = false
    /// Every session the publisher is watching, when it reports them.
    /// Empty for a publisher that predates the snapshot.
    var sessions: [SessionSummary] = []

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

        if age > staleAfter {
            // A killed DSH must not leave a light on: the heartbeat is gone,
            // so the last state is no longer a claim about right now. The
            // detail stays free of the live age so the signature is stable.
            return Reading(
                light: .broken,
                detail: String(format: "stale (heartbeat %.1fs)", heartbeatMs / 1000),
                sessionId: sessionId,
                age: age,
                stale: true
            )
        }

        var sessions: [SessionSummary] = []
        if let meta = object["meta"] as? [String: Any],
           let reported = meta["sessions"] as? [[String: Any]] {
            sessions = reported.compactMap { item in
                guard let id = item["id"] as? String, let state = item["state"] as? String else {
                    return nil
                }
                let changedAt = (item["changedAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                return SessionSummary(id: id, state: Light(published: state), changedAt: changedAt)
            }
        }

        // An unrecognised value is rest, not failure: the feed is healthy and
        // simply says something this build has not learned yet.
        let light = Light(published: object["state"] as? String ?? "")
        return Reading(
            light: light,
            detail: reason,
            sessionId: sessionId,
            age: age,
            publishedAt: Date(timeIntervalSince1970: updatedAtMs / 1000),
            changedAt: changedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            sessions: sessions
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
    var diameter: CGFloat = 24
    var interval = 0.25
    /// Bundle identifiers whose return to the front acknowledges a finish.
    var ackTargets: Set<String> = []
    /// Appearance overrides; nil means "use whatever was chosen last".
    var style: LightStyle?
    var orientation: LightOrientation?
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
          apps. DOUBLE-CLICK it to switch between DSH and the application you
          came from, whatever colour is showing; drag it to reposition. A single
          click does nothing on purpose.
          LEVEL is floating, status or screensaver (default screensaver).

          A green finish rests as soon as you come back to DSH — either by
          switching to it or by clicking the light — because the reminder has
          been served. --ack-app adds another application whose return counts;
          repeat it for several. The default is the application named by
          --open. --no-ack keeps green until the next prompt instead.

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
                if let raw = value(), let points = Double(raw), points > 4 { options.diameter = CGFloat(points) }
            case "--style":
                options.style = value() == "nostalgic" ? .nostalgic : .classic
            case "--orientation":
                options.orientation = value() == "vertical" ? .vertical : .horizontal
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

/// Two visual languages. A style never assumes an orientation: the two are
/// independent axes, and every combination has to work.
enum LightStyle: String, CaseIterable {
    case classic
    case nostalgic

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .nostalgic: return "Nostalgic"
        }
    }
}

enum LightOrientation: String, CaseIterable {
    case horizontal
    case vertical

    var title: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

/// Lens measurements for one style, in one place, so the window size, the
/// drawing and the snapping cannot disagree about how big the light is.
struct LightGeometry {
    var lens: CGFloat
    var gap: CGFloat
    var padding: CGFloat
    var housing: Bool

    static func of(_ style: LightStyle) -> LightGeometry {
        switch style {
        case .classic: return LightGeometry(lens: 18, gap: 8, padding: 8, housing: false)
        case .nostalgic: return LightGeometry(lens: 26, gap: 10, padding: 10, housing: true)
        }
    }

    func size(_ orientation: LightOrientation) -> NSSize {
        let lenses = 3
        let length = CGFloat(lenses) * lens + CGFloat(lenses - 1) * gap + 2 * padding
        let breadth = lens + 2 * padding
        return orientation == .horizontal
            ? NSSize(width: length, height: breadth)
            : NSSize(width: breadth, height: length)
    }
}

/// Which border the light is docked to. Remembered, because the menu is placed
/// flush to the same one.
enum ScreenBorder: String {
    case left, right, top, bottom
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
    var style: LightStyle = .classic {
        didSet { needsDisplay = true }
    }
    var orientation: LightOrientation = .horizontal {
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
    /// When the first of the two clicks landed, so the dot can show it arrived.
    private var pendingUntil: Date?

    /// A slow breath rather than a blink: a session blocked on the user should
    /// read as alive, not as an alarm. It never goes fully dark.
    private static let breathPeriod: Double = 2.6
    private static let breathFloor: Double = 0.25
    private var breathEpoch = Date()
    private var breathTimer: Timer?

    deinit {
        breathTimer?.invalidate()
    }

    private var needsBreathing: Bool {
        reading.light == .asking
    }

    /// A redraw clock that runs only while something is breathing.
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

    /// Full brightness, except for the yellow lens when it is breathing.
    private func level(for lens: Lens) -> Double {
        guard lens == .yellow, needsBreathing else { return 1 }
        let phase = Date().timeIntervalSince(breathEpoch)
            .truncatingRemainder(dividingBy: Self.breathPeriod) / Self.breathPeriod
        return Self.breathFloor + (1 - Self.breathFloor) * (0.5 + 0.5 * sin(2 * .pi * phase))
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

    /// Lenses in fixed order, laid out along the current axis.
    private func lensRects() -> [(Lens, NSRect)] {
        let geometry = LightGeometry.of(style)
        let step = geometry.lens + geometry.gap
        return [Lens.red, .yellow, .green].enumerated().map { index, lens in
            let distance = CGFloat(index) * step
            let rect: NSRect
            if orientation == .horizontal {
                rect = NSRect(
                    x: geometry.padding + distance,
                    y: geometry.padding,
                    width: geometry.lens,
                    height: geometry.lens
                )
            } else {
                rect = NSRect(
                    x: geometry.padding,
                    y: bounds.height - geometry.padding - geometry.lens - distance,
                    width: geometry.lens,
                    height: geometry.lens
                )
            }
            return (lens, rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let geometry = LightGeometry.of(style)
        let lit = litLens()

        if geometry.housing {
            let body = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: min(bounds.width, bounds.height) / 3,
                yRadius: min(bounds.width, bounds.height) / 3
            )
            NSColor(calibratedWhite: 0.13, alpha: 0.92).setFill()
            body.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            body.lineWidth = 1
            body.stroke()
        }

        for (lens, rect) in lensRects() {
            let isLit = lens == lit
            draw(lens: lens, in: rect, lit: isLit, level: isLit ? level(for: lens) : 0, housing: geometry.housing)
        }

        if let until = pendingUntil, Date() < until {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func draw(lens: Lens, in rect: NSRect, lit: Bool, level: Double, housing: Bool) {
        let colour = colour(of: lens)
        if lit {
            colour.withAlphaComponent(level).setFill()
        } else {
            // Unlit is glass, not a hole: tinted in the housing, muted in the
            // flat style, so the light keeps its shape when nothing happens.
            colour.withAlphaComponent(housing ? 0.10 : 0.18).setFill()
        }
        NSBezierPath(ovalIn: rect).fill()

        if housing {
            // The beginnings of a glass read: a highlight in the upper left,
            // brighter when the lens is lit. The texture is refined later.
            let shine = NSRect(
                x: rect.minX + rect.width * 0.20,
                y: rect.minY + rect.height * 0.58,
                width: rect.width * 0.42,
                height: rect.height * 0.24
            )
            NSColor.white.withAlphaComponent(lit ? 0.18 + 0.22 * level : 0.05).setFill()
            NSBezierPath(ovalIn: shine).fill()
        }

        NSColor.black.withAlphaComponent(housing ? 0.45 : 0.22).setStroke()
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
    private var timer: Timer?
    private let finishes = FinishTracker()
    private var style: LightStyle = .classic
    private var orientation: LightOrientation = .horizontal
    private var border: ScreenBorder = .right
    /// How far the light sits from the border it is docked to.
    private static let dockInset: CGFloat = 10
    private lazy var acknowledgement: Acknowledgement? = options.ackDisabled
        ? nil
        : Acknowledgement(targets: options.ackTargets, fallbackAppPath: options.openTarget)

    private static let originKey = "DSHLight.windowOrigin"
    private static let styleKey = "DSHLight.style"
    private static let orientationKey = "DSHLight.orientation"
    private static let borderKey = "DSHLight.border"

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        style = options.style
            ?? LightStyle(rawValue: defaults.string(forKey: Self.styleKey) ?? "")
            ?? .classic
        orientation = options.orientation
            ?? LightOrientation(rawValue: defaults.string(forKey: Self.orientationKey) ?? "")
            ?? .horizontal
        border = ScreenBorder(rawValue: defaults.string(forKey: Self.borderKey) ?? "") ?? .right

        let size = LightGeometry.of(style).size(orientation)
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

        let view = TrafficLightView(frame: NSRect(origin: .zero, size: size))
        view.style = style
        view.orientation = orientation
        view.onTap = { [weak self] in self?.navigate() }
        view.onMove = { [weak self] _ in self?.dock() }
        view.onMenu = { [weak self] in self?.showMenu() }
        window.contentView = view

        window.setFrameOrigin(restoredOrigin(size: size))
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        dock()

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard let view else { return }
        acknowledgement?.poll()
        let raw = StateFile.read(at: options.statePath)
        let reading = displayed(raw, acknowledgedBy: acknowledgement, finishObservedAt: finishes.note(raw))
        // Redraw only when the colour actually changes: the light is idle most
        // of the time, and the reading itself changes every heartbeat tick.
        if reading.light != view.reading.light {
            view.reading = reading
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

    /// Flush to whichever border of its screen is nearest, and remember which,
    /// because the menu is placed against the same one.
    private func dock() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let candidates: [(ScreenBorder, CGFloat)] = [
            (.left, abs(frame.minX - visible.minX)),
            (.right, abs(visible.maxX - frame.maxX)),
            (.top, abs(visible.maxY - frame.maxY)),
            (.bottom, abs(frame.minY - visible.minY))
        ]
        border = candidates.min { $0.1 < $1.1 }?.0 ?? .right

        var origin = frame.origin
        switch border {
        case .left: origin.x = visible.minX + Self.dockInset
        case .right: origin.x = visible.maxX - frame.width - Self.dockInset
        case .top: origin.y = visible.maxY - frame.height - Self.dockInset
        case .bottom: origin.y = visible.minY + Self.dockInset
        }
        window.setFrameOrigin(origin)

        UserDefaults.standard.set(border.rawValue, forKey: Self.borderKey)
        UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
    }

    /// Restore the last position, clamped onto a screen that still exists — a
    /// display that went away must not strand the light off-screen.
    private func restoredOrigin(size: NSSize) -> NSPoint {
        guard let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double],
              saved.count == 2 else {
            return defaultOrigin(size: size)
        }
        let candidate = NSRect(x: saved[0], y: saved[1], width: size.width, height: size.height)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(candidate) }
        return visible ? candidate.origin : defaultOrigin(size: size)
    }

    /// Top-right of the main screen's visible frame, clear of the menu bar.
    private func defaultOrigin(size: NSSize) -> NSPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(
            x: frame.maxX - size.width - Self.dockInset,
            y: frame.maxY - size.height - Self.dockInset
        )
    }

    // MARK: Menu

    /// The list hangs inward from the border the light is docked to, so a docked
    /// light never opens a menu off the edge of the screen.
    private func showMenu() {
        guard let window else { return }
        let menu = buildMenu()
        let frame = window.frame
        let width = menu.size.width
        let height = menu.size.height
        let anchor: NSPoint
        switch border {
        case .right: anchor = NSPoint(x: frame.minX - width, y: frame.maxY)
        case .left: anchor = NSPoint(x: frame.maxX, y: frame.maxY)
        case .top: anchor = NSPoint(x: frame.minX, y: frame.minY - height)
        case .bottom: anchor = NSPoint(x: frame.minX, y: frame.maxY)
        }
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    /// Groups in one list, so a future feature is one entry — and a single
    /// column gives every row the same width for free.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(header("Style"))
        for style in LightStyle.allCases {
            let item = choice(style.title, on: style == self.style, action: #selector(chooseStyle(_:)), tag: 0)
            item.representedObject = style
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("Orientation"))
        for orientation in LightOrientation.allCases {
            let item = choice(
                orientation.title,
                on: orientation == self.orientation,
                action: #selector(chooseOrientation(_:)),
                tag: 0
            )
            item.representedObject = orientation
            menu.addItem(item)
        }

        // Reserved: the next feature goes here, between separators.
        menu.addItem(.separator())
        menu.addItem(.separator())

        menu.addItem(choice("Quit the light", on: false, action: #selector(quit), tag: 0))
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func choice(_ title: String, on: Bool, action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.tag = tag
        return item
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? LightStyle else { return }
        self.style = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
        refit()
    }

    @objc private func chooseOrientation(_ sender: NSMenuItem) {
        guard let orientation = sender.representedObject as? LightOrientation else { return }
        self.orientation = orientation
        UserDefaults.standard.set(orientation.rawValue, forKey: Self.orientationKey)
        refit()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Re-fit the window after a style or orientation change, keeping the corner
    /// furthest from the docked border, so the light grows inward rather than
    /// jumping across the screen.
    private func refit() {
        guard let window, let view else { return }
        let size = LightGeometry.of(style).size(orientation)
        let old = window.frame
        var origin = old.origin
        switch border {
        case .right: origin.x = old.maxX - size.width
        case .left: origin.x = old.minX
        case .top: origin.y = old.maxY - size.height
        case .bottom: origin.y = old.minY
        }
        view.style = style
        view.orientation = orientation
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        dock()
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
