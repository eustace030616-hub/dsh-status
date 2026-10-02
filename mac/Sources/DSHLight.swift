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
    case broken

    /// Fold a published `state` onto a light. Anything unrecognised becomes
    /// `idle`, never `broken`, so adding a state later can never make an older
    /// renderer cry wolf — and a legacy `unknown` from an older publisher reads
    /// as rest rather than as failure.
    init(published: String) {
        switch published {
        case "working": self = .working
        case "waiting": self = .waiting
        default: self = .idle
        }
    }
}

/// How many heartbeats may pass before the feed is called dead.
private let staleAfterHeartbeats = 3.0
private let fallbackHeartbeatMs = 2000.0
private let defaultStatePath =
    ("~/Library/Application Support/dsh-status/state.json" as NSString).expandingTildeInPath

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
        case .broken: return "🔴"
        }
    }

    var label: String {
        switch light {
        case .idle: return "idle"
        case .working: return "working"
        case .waiting: return "waiting"
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

        // An unrecognised value is rest, not failure: the feed is healthy and
        // simply says something this build has not learned yet.
        let light = Light(published: object["state"] as? String ?? "")
        return Reading(
            light: light,
            detail: reason,
            sessionId: sessionId,
            age: age,
            publishedAt: Date(timeIntervalSince1970: updatedAtMs / 1000),
            changedAt: changedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
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
final class Acknowledgement {
    private static let storedKey = "DSHLight.acknowledgedAt"

    private let targets: Set<String>
    private var previousFrontmost: String?
    private(set) var at: Date?

    init(targets: Set<String>, fallbackAppPath: String) {
        var resolved = targets
        if resolved.isEmpty, let identifier = TargetApp.bundleIdentifier(of: fallbackAppPath) {
            resolved = [identifier]
        }
        self.targets = resolved
        let stored = UserDefaults.standard.double(forKey: Acknowledgement.storedKey)
        if stored > 0 { self.at = Date(timeIntervalSince1970: stored) }
        // Whatever is in front now was not "coming back": only a later change is.
        self.previousFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var targetDescription: String {
        targets.isEmpty ? "none — acknowledgement is off" : targets.sorted().joined(separator: ", ")
    }

    /// Note a return to DSH. Returns true only on the transition, so a user who
    /// stays in DSH does not keep re-acknowledging.
    @discardableResult
    func poll() -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        defer { previousFrontmost = frontmost }
        guard let frontmost, frontmost != previousFrontmost, targets.contains(frontmost) else {
            return false
        }
        acknowledge()
        return true
    }

    func acknowledge() {
        let now = Date()
        at = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Acknowledgement.storedKey)
    }

    /// True when this finish happened before the user came back.
    func covers(_ publishedAt: Date?) -> Bool {
        guard let at, let publishedAt else { return false }
        return at >= publishedAt
    }
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
    guard reading.light == .waiting else { return reading }
    guard let finishAt = reading.changedAt ?? finishObservedAt else { return reading }
    guard acknowledgement?.covers(finishAt) == true else { return reading }
    var settled = reading
    settled.light = .idle
    settled.detail = "\(reading.detail) · back in dsh"
    return settled
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
          apps. Click it to bring DSH forward, drag it to move it.
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
    while true {
        acknowledgement?.poll()
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

final class DotView: NSView {
    var reading = Reading.broken("starting") {
        didSet { needsDisplay = true }
    }
    var onTap: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?

    private var originAtDragStart: NSPoint?
    private var mouseAtDragStart: NSPoint?
    private var dragged = false

    private func colour(for light: Light) -> NSColor {
        switch light {
        case .idle: return .systemGray
        case .working: return .systemYellow
        case .waiting: return .systemGreen
        case .broken: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 8, dy: 8)
        // A pale halo keeps the dot readable on a dark wallpaper; the dot's own
        // colour carries on a light one.
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()

        colour(for: reading.light).setFill()
        NSBezierPath(ovalIn: dot).fill()

        NSColor.black.withAlphaComponent(0.22).setStroke()
        let edge = NSBezierPath(ovalIn: dot)
        edge.lineWidth = 1
        edge.stroke()
    }

    // Manual drag so that a click and a drag can share one small target.
    override func mouseDown(with event: NSEvent) {
        originAtDragStart = window?.frame.origin
        mouseAtDragStart = NSEvent.mouseLocation
        dragged = false
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
        } else {
            onTap?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var window: NSWindow?
    private var view: DotView?
    private var timer: Timer?
    private let finishes = FinishTracker()
    private lazy var acknowledgement: Acknowledgement? = options.ackDisabled
        ? nil
        : Acknowledgement(targets: options.ackTargets, fallbackAppPath: options.openTarget)
    private static let originKey = "DSHLight.windowOrigin"

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let side = options.diameter + 16
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
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

        let view = DotView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.onTap = { [weak self] in
            // A click is a deliberate "take me there", so it settles the light
            // even when DSH was already in front and no switch will be seen.
            self?.acknowledgement?.acknowledge()
            self?.refresh()
            self?.bringHarnessForward()
        }
        view.onMove = { origin in
            UserDefaults.standard.set([origin.x, origin.y], forKey: AppDelegate.originKey)
        }
        window.contentView = view

        window.setFrameOrigin(restoredOrigin(side: side))
        window.orderFrontRegardless()

        self.window = window
        self.view = view

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
        // Redraw only when the colour actually changes: the dot is idle most of
        // the time, and the reading itself changes every heartbeat tick.
        if reading.light != view.reading.light {
            view.reading = reading
        }
    }

    private func bringHarnessForward() {
        let url = URL(fileURLWithPath: options.openTarget)
        if !NSWorkspace.shared.open(url) {
            FileHandle.standardError.write("DSHLight: cannot open \(options.openTarget)\n".data(using: .utf8)!)
        }
    }

    /// Restore the last position, clamped onto a screen that still exists —
    /// a display that went away must not strand the light off-screen.
    private func restoredOrigin(side: CGFloat) -> NSPoint {
        guard let saved = UserDefaults.standard.array(forKey: AppDelegate.originKey) as? [Double],
              saved.count == 2 else {
            return defaultOrigin(side: side)
        }
        let candidate = NSRect(x: saved[0], y: saved[1], width: side, height: side)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(candidate) }
        return visible ? candidate.origin : defaultOrigin(side: side)
    }

    /// Top-right of the main screen's visible frame, clear of the menu bar.
    private func defaultOrigin(side: CGFloat) -> NSPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(x: frame.maxX - side - 16, y: frame.maxY - side - 16)
    }
}

func runWindowMode(_ options: Options) {
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
