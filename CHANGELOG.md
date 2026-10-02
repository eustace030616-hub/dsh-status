# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

**Two versions move independently, and the one that matters is the second:**

- the **package version** (below), which is what you re-install to pick up;
- the **contract version** — the `version` field inside the published state document. That is the
  real compatibility boundary between this publisher and the renderer that reads it. It is bumped
  only when a reader written against the old shape would be *wrong*, and every other change is
  additive: new keys are added, never renamed or removed, and new information goes inside `meta`.

## [Unreleased]

## [0.7.0] - 2026-10-02

### Added

- **The account balance is real.** The publisher makes one authenticated
  `GET https://api.deepseek.com/user/balance` every `balanceMs` (default five minutes, floor of one) and
  publishes the answer as `meta.account`: `{ fetchedAt, intervalMs, isAvailable, balances: [{ currency,
  total, granted, toppedUp }] }`. Additive inside `meta`, so the contract stays version 1 and a reader that
  has never heard of an account ignores it.
- **The `Account` group draws those figures** — one folded group per currency, because the endpoint answers
  in more than one, with a footer saying how old the answer is and marking it stale after three missed
  lookups. A present-but-empty block reads as "never fetched"; a publisher with no account block at all
  still reads as "no source wired up yet".
- **`test/balance.js`**, 13 checks against every answer the endpoint can give — figures, a refused key, a
  server error, a dead connection, a timeout, an unreadable body — with the `fetch` handed in, so the suite
  needs no network and no key. Six more checks in `test/run.js` drive a whole lookup through the plugin with
  the network, the credential seam and the timers under test control.
- **A `Secrets` section in the README**, recording how the key is kept out of this project: the value is
  resolved at request time through the credential seam and never stored, `describe()` answers "is a key
  configured?" without a value, error bodies are mapped to codes, the key never reaches a child process, and
  the tests inject a canary secret and assert it surfaces nowhere. It also records the rule for working on
  the code, which is the part that gets forgotten: never print a credential value, describe one by
  existence, source and length, and rotate one that escapes rather than trying to scrub the transcript.

### Changed

- **A failure to read the account is a code, never a message.** `no-key`, `unauthorized`, `offline`,
  `timeout`, `http-503`, `bad-body`: the provider's own 401 quotes part of the key it rejected, so a body is
  read only when the answer was a good one. One warning per change of reason, not one per attempt.
- **The lookup cannot reach the state machine.** It is written into `meta` with a targeted write rather than
  a publish, so the headline, its stamps and the light are left exactly as they were: red stays reserved for
  a feed that cannot be trusted, and `is_available: false` is a row in the list rather than a lens.
- **The key is resolved through the credential seam at request time** — `ctx.credentials.resolve(ref)` when
  the composition has one, the ambient `DEEPSEEK_API_KEY` when it does not — and lives for one request. The
  seam is deliberately **not** declared in `inject`: a plugin that waits for a service a custom composition
  lacks would never mount, and a profile that cannot boot is worse than a missing balance.
- **The state-machine tests no longer spawn renderers or reach the network.** Every mount in `test/run.js`
  passes `launch: false, balance: false`; before this a suite run left stray lights behind, and would now
  have made real balance requests with the real key.

## [0.6.4] - 2026-10-02

### Changed

- **The grey body behind the lenses is thirty percent fainter** — `bodyOpacity`, 0.7 against the material's
  own strength. The body and the light are **siblings now rather than parent and child**: a view's alpha
  applies to everything inside it, so leaving the lenses nested in the body would have faded them with it.
- **The body's corner radius comes from its narrow side.** It was taken from the height, which was the narrow
  side back when the light could lie down; a 32-point-wide body with a radius of 14 is a lozenge with four
  points of straight edge, not the rounded square it is meant to be.

## [0.6.3] - 2026-10-02

### Changed

- **No highlight on the lenses.** A white highlight in the upper left made them read as glass, and at this
  size it was the busiest thing on the screen. A lens is a flat disc with a rim now.
- **The sliders are folded into an `Appearance` group.** The list is a list of lists: anything with several
  numbers inside it is a folded group, so the first level stays down to what the light can say at a glance.
  Folded by default, and the values inside are exactly the ones the light was already wearing.

### Added

- **An `Account` group, empty on purpose.** The shape is what is being settled: `Balance`, `Today` and
  `This month` with a column for the figures, dashes in that column, and a last row saying there is no
  source wired up yet, because a dash on its own can be read as a bug. `ValueRow.show(_:)` is where a real
  number will arrive.

## [0.6.2] - 2026-10-02

### Changed

- **Horizontal mode is gone: the light is always a traffic light.** Three lenses stacked, red at the top,
  docked to the left or right side of the screen and free to slide up and down that side. The row of lenses
  along the top edge is what made the menu bar a problem worth solving, and the solution — measuring the
  bar's own window and moving the light with it — was worse than the problem: a laggy light that overlapped
  the bar it was following by a point or two. One shape, one axis, no tracking.
- **Nothing follows the menu bar any more.** The bar's height is held back statically at
  `NSStatusBar.thickness`, and a side-docked light is clamped so its top edge can never reach that strip.
  That is a rule with no timer in it, which is the point.
- **A drop anywhere picks the nearer side.** Dragging the light up to the top of the screen now lands it on
  the left or right edge at that height, clear of the bar rather than under it — checked from six starting
  positions, including the top centre and one above the screen.

### Removed

- `LightOrientation`, the top and bottom docking borders, the corner zone that existed only to stop a change
  of shape from resizing the light, and the two menu-bar functions with their 60 Hz follow loop.

### Fixed

- **`mac/Resources/Info.plist` had been emptied** while bumping the version, which left the bundle without
  its identifier, its display name or `LSUIElement`. A bundle like that cannot be launched as an application:
  macOS runs the executable bare, in a defaults domain of its own, so the light came up in its default size
  and forgot the look and position it had been given. Restored from the previous commit and versioned
  properly — by reading the file before writing it, which is what the one-liner had got wrong.

## [0.6.1] - 2026-10-02

### Changed

- **A top-docked light hugs the screen edge and rides the menu bar.** The bar's height used to be reserved
  unconditionally, which parked the light 34 points down even with the bar hidden. The bar is measured now
  and the light follows it: 6 points below the screen edge while the bar is away, 6 points below the bar
  while it is down, and back up when it goes. The top gap is 6 points; the side and bottom gaps are
  unchanged at 10.
- **The light follows the slide rather than arriving after it.** The state-file tick notices the bar move
  and a 60 Hz loop rides it until it stops. A light on any other border keeps the position it was given
  and is only pushed clear if the bar would otherwise be drawn over it.

### Fixed

- **The bar is measured instead of assumed.** `NSScreen.visibleFrame` cannot answer this: with
  "automatically hide and show the menu bar" on it reports the whole screen in *both* states — 1680×1050
  against a 1680×1050 frame, bar up or bar down. The bar is its own window: layer 24, as wide as the
  screen, with bounds measured down from the top of the main display, so a bar that is out of the way sits
  at a negative y and the part that has come down is `y + height` from the screen's edge.
- **The reserved height is capped at `NSStatusBar.thickness`, which is 22, not the 24 this build had
  assumed.** The bar's window is taller than the bar — 30 against 22, eight points of blur hanging past
  it — and capping makes the answer independent of how that blur is laid out, and equal to what a system
  that shows the bar permanently reserves.

## [0.6.0] - 2026-10-02

### Changed

- **The styles are gone; the light is four numbers instead.** There is no style to choose any more. The
  right-click list holds one slider each for the size of a lens, the gap between the lenses, and how solid
  a resting and a lit lens are, and the values are remembered. The two styles were the same object
  differing only in glass, and a pair of presets is a poor way to ask for a size — a slider says what it
  does.
- **A slider applies as it is dragged.** Every step re-fits and re-anchors the window, so the light on
  screen is the preview rather than a change that lands when the list closes.
- **While the list is open the light drops a level**, below the menu. It outranks a menu on purpose, and
  with sliders in the list a lens growing across a row would otherwise take the clicks meant for it.
- **A slider is a small hand-drawn control rather than an `NSSlider`.** The one event a menu is documented
  to push into a view it hosts is the mouse — `mouseDown:`, `mouseDragged:`, `mouseUp:` — while a stock
  `NSSlider` pulls its own drags out of the event queue instead. The knob snaps to whole points and whole
  percents, so it can always reach the value the readout prints.

### Added

- **A migration that keeps the size you had.** The first run after the upgrade reads the old style once,
  turns it into slider values — `classic` becomes 22 points and an 8 point gap, `nostalgic` 31 and 10 —
  and forgets the style.

### Fixed

- **The list is placed exactly flush on every border.** `popUp(positioning:at:in:)` lands a menu's top five
  points above the point it is given, which was measured on menus of two different heights. It used to go
  unnoticed because the light outranked the list and swallowed the overlap; the placement is now worked out
  in the list's own top-left corner and converted at the end.
- **Two adjacent separators are one row of height, not two.** AppKit collapses consecutive separators when
  it draws but counts both in `menu.size`, which is the number the placement comes from — the reserved
  group is one separator now, and a bottom-docked light is no longer eleven points off.
- **`--size POINTS` now does something.** It was parsed and thrown away before, which made it a flag that
  did nothing; it now sets the lens size for one run, overriding the slider.

## [0.5.6] - 2026-10-02

### Fixed

- **A light docked to the top edge sat inside the menu bar.** With "automatically hide and show the menu
  bar" on, `NSScreen.visibleFrame` covers the whole screen — measured here as 1680×1050 against a
  1680×1050 frame — so docking 10 points from the top put the light exactly where the bar drops. The
  usable area now reserves `NSStatusBar.thickness` worth of menu bar whether or not the system reports it
  as hidden, so a top-docked light sits clear of the bar instead of under it.

## [0.5.5] - 2026-10-02

### Fixed

- **The right-click list opened a menu-height away from a light docked to the top or bottom edge.**
  `popUp(positioning:at:in:)` puts the menu's *top-left* corner at the given point; the placement math
  read those y values as the menu's bottom, so a horizontal light got a gap exactly the height of the
  list. A side-docked light was unaffected because the two tops line up anyway, which is why it only
  showed horizontally. The list is also clamped inside the visible frame now, so no border can open one
  off the screen.

## [0.5.4] - 2026-10-02

### Changed

- **The light sits on the menu's own material.** It floats on `NSVisualEffectView` with the `menu`
  material, so the right-click list matches it exactly rather than approximately — the list reads as an
  extension of the light instead of a separate object. It also gives the light a faint grey body on any
  wallpaper and follows light and dark appearance without a colour of its own.
- **The dark body is gone from the nostalgic style**, because the shared backdrop took its place. The
  style now differs in the lenses — a highlight and a heavier rim — rather than in the housing they sit
  in, so both styles are the same object with different glass.

## [0.5.3] - 2026-10-02

### Changed

- **Lenses are 20% larger** — 18 to 22 points in the flat style, 26 to 31 in the housing, rounded to whole
  points so the circles stay crisp. The gaps are unchanged, so the light reads as chunkier bulbs in the
  same shape.
- **Rest is 20% and lit is 80%.** One resting value for both styles, so rest looks the same either way,
  and a lit lens stops short of opaque so it keeps reading as glass.

## [0.5.2] - 2026-10-02

### Fixed

- **A corner can no longer turn the light.** Around a corner the nearest border is a coin toss, so
  nudging the light there flipped the orientation, which resized it — and a horizontal light that became
  vertical left a lens or two off the screen. A drop within 60 points of a second border now keeps the
  direction it had; only a drop clear of a corner can change it. The final position is clamped inside the
  visible frame as a last guarantee.

### Changed

- **Resting lenses are visible and lit ones are not flat.** A resting lens went from 18% to 32% opacity
  in the flat style and from 10% to 24% in the housing, so the traffic light reads as one when nothing is
  lit; a lit lens is now 10% down from opaque, which keeps it looking like glass rather than a sticker.


## [0.5.1] - 2026-10-02

### Changed

- **The docked border decides the orientation.** A light on a side edge stacks its lenses; on a top or
  bottom edge it lays them in a row, so it always grows *along* the border rather than across it and the
  docking reads as deliberate. The orientation group left the right-click list and `--orientation` went
  with it: a setting that could contradict where the light actually is had no business existing.
- **The click acknowledgement is a rounded square, not a ring.** At this size a circle read as part of
  the light rather than as feedback about the click.


## [0.5.0] - 2026-10-02

### Changed

- **The dot is a traffic light.** Three lenses instead of one bulb, because three states were competing
  for it and grey had to carry "rest": red is a feed that cannot be trusted, yellow is work, breathing
  yellow is a session blocked on you, green is an unread finish, and **all three dark is rest** — which
  is what a traffic light with nothing to say looks like. Blue is gone; a blocked session breathes the
  yellow lens on a slow 2.6 s cycle, dipping to a quarter brightness rather than blinking, so it reads
  as alive instead of as an alarm.
- **The light docks to the nearest screen border** when dropped, and remembers which one. The right-click
  list opens flush to that border, hanging inward, so an edge-docked light never opens a menu off the
  edge of the screen.
- **A right-click list**, built as groups so the next feature is one entry: style, orientation and a
  reserved group between separators. A single column gives every row the same width.
- **Appearance is two independent axes.** Style (classic macOS circles, or nostalgic bulbs in a housing)
  and orientation (horizontal or vertical) combine freely, persist between runs, and can be overridden
  with `--style` and `--orientation`.

### Fixed

- **A lock that cannot be opened no longer blocks the light.** The singleton lock read "could not create
  the lock file" as "another light is running", so a confined or read-only environment refused to draw
  at all. It now runs without one and says why.


## [0.4.0] - 2026-10-02

### Added


### Changed

- **The renderer ships inside the plugin, and the plugin runs it.** `bin/` carries the built universal
  bundle, so a plugin-page install is the whole light: no clone, no Xcode, no build step and no
  hand-launching. The plugin starts it once the first state is published — so the dot never has to draw
  a missing file — stops it on dispose, and leaves it alone on any platform that is not macOS. Setting
  `launch: false` opts out, and `lightArgs` passes renderer arguments through, which is how a
  browser-hosted DSH gets its `--open` and `--ack-app`.
- **One light only.** The renderer takes an exclusive `flock` for the life of its process, so the
  plugin's instance and a hand-launched one cannot both draw. The kernel releases it on exit, so a crash
  cannot strand the lock — which is why it is a lock and not a pid file.
- **A drift guard for the committed bundle.** The binary records the digest of the Swift source it was
  built from and `npm test` compares the two, so editing the renderer without running `npm run ship`
  fails the suite rather than shipping a stale dot.
- **Being in DSH acknowledges, not just arriving.** Green settled only when DSH *became* frontmost, so a
  turn finishing while the user was already looking at DSH stayed green until they left and came back —
  and the only way to clear it was to click. Looking at DSH is having read it: the acknowledgement now
  refreshes whenever DSH is in front, which is the reminder's whole purpose and covers the case a
  transition cannot see. While the user stays there it refreshes every tick, so the stored value is
  written every few seconds rather than four times a second.

### Planned

- **Stage 3 — wiring.** The plugin spawns the renderer and reaps it on dispose. This is the point at
  which the built binary must be added to the `files` allow-list, or installed copies will break
  while a source checkout keeps working.
- Session `title`, currently always `null`: the title exists in the session log, but which accessor
  exposes it is unconfirmed.
- A second root agent. `agent/created` overwrites the recorded session, so concurrent root agents
  would make the published state follow whichever spoke last.

## [0.3.0] - 2026-10-02

### Added

- **Several sessions at once.** The publisher held one headline state, so whichever session spoke last
  decided the light: with two running, one finishing turned it green while the other was still working,
  and nothing could say otherwise. Every root session now keeps its own entry — state, reason and
  `changedAt` — published in `meta.sessions`, while the top-level `state` stays the most urgent of them
  so readers that understand only one keep working. An ask is charged to the session that owns it, so a
  subagent blocked on an approval marks its parent rather than becoming a session of its own.
- **The renderer aggregates, because only it knows what you have read.** A blocked session outranks
  everything; an unread finish outranks work, so a finish is never swallowed by another session's work;
  then work; then rest. That is what makes the light turn **yellow rather than grey** once you have read
  one finish while another session is still busy.

## [0.2.0] - 2026-10-02

### Changed

- **`idle` replaces `unknown` as the published rest state, and rest is grey rather than red.** The
  old vocabulary had one word for two different things: a session switch or a fresh boot reported
  `unknown`, which readers drew as red — so the light cried wolf in the least alarming moment there
  is. The publisher now reports `idle` (rest), and the renderer reserves **red for the feed itself
  being broken**: no file, unreadable, no timestamp, or a heartbeat that stopped. Grey means the feed
  is healthy and nothing is pending.
- **An unrecognised `state` now degrades to rest, never to red.** A renderer that meets a value it has
  never heard of says "not something I know", not "something is wrong" — so adding a state later can
  never make an older renderer alarm. A legacy `unknown` therefore reads as grey too, which fixes the
  red flash on session switch even before the publisher is updated.
- Green keeps its meaning as an **unacknowledged** finish. Switching sessions or sending the next
  prompt ends it, which is what "the green has reached its goal" means in practice; tapping the light
  deliberately does *not* clear it, because a glance is not the same as having read the answer.

### Added

- **Stage 2 — the renderer (`mac/`).** `DSHLight.app`, a universal ad-hoc-signed dot that reads the
  state document and draws yellow (working), green (finished, unacknowledged), grey (rest) or red
  (broken feed) above every window, on every Space, and over another application's fullscreen window.
  It clicks through to DSH and drags to reposition, remembering the position; a display that
  disappears cannot strand it off-screen. `./mac/build.sh` produces the bundle; it needs no Apple
  Developer account.
- **`--print` mode**, a persistent follower for inspecting the light without a window: it prints the
  current light at once, then only when the light or its reason changes. Colour is emitted only when
  stdout is a terminal.
- `changedAt` in the state document: when the current state was asserted, as distinct from when the
  publisher was last heard from.
- Launch flags: `--state-file`, `--print`, `--interval`, `--open`, `--level`, `--size`.
- **Blue: the agent is blocked on the user.** A permission prompt (`approval/request`) or a question
  (`user-questions/request`) reports `asking`, which the light draws blue and treats as a call for
  attention. Both seams are waterfalls, so the publisher observes by publishing before delegating and
  returning the real answerer's result untouched; concurrent asks are counted, and the light stays
  blue until the last one is answered. Deliberately not root-filtered — a subagent's approval still
  needs the human — which is the one place the root filter does not apply.
- **The double-click navigates and nothing else.** It switches between DSH and the application the
  user came from, in whichever direction they are pointing, *whatever colour is showing*. State no
  longer decides what a click does: the colour answers "should I go?", the click does the going. The
  acknowledgement follows from that — arriving at DSH is what settles a finish — so the gesture needs
  no knowledge of state at all.
- **Every click action now needs a double-click.** A single click is inert, so a stray one while the
  user is working elsewhere cannot take their screen; and the gesture is explicit, which also removes
  the race where two quick clicks could land in either application depending on whether the first
  activation had been observed yet. Dragging is still a plain drag.
- **A click toggles between the answer and the work.** Green, blue and red bring DSH forward, because
  something finished, is blocked, or is broken. Grey and yellow toggle both ways: back to the
  application the user came from when DSH is in front, and forward to DSH when it is not — a way in as
  well as a way out. With nowhere to return to it says so instead of doing nothing. It restores the application rather than the window or tab — as far as
  public API reaches — and remembers neither DSH nor the light itself, since returning to either
  would be a no-op. Found while testing: the light *does* briefly become frontmost when it launches,
  which was enough for it to remember itself and make the return click do nothing.
- **Acknowledgement by return.** A green finish settles to grey once the user is back at DSH — either
  by switching to it or by clicking the light — because the reminder has been served. The
  acknowledgement is Mac-side (the harness has no idea which window is in front), it is stored, and it
  is compared against the finish's `updatedAt`, so a *newer* finish is green again rather than being
  swallowed by an older acknowledgement. `--ack-app BUNDLE-ID` adds an application whose return
  counts, repeatable; `--no-ack` turns the whole thing off and keeps green until the next prompt.

### Fixed

- **Every gesture cost one extra click.** AppKit uses the first click on an inactive window *only* to
  activate it and never delivers it, so a single click needed two and a double-click needed three. The
  view now accepts the first click, and the dot draws a ring while a first click waits for its partner:
  a two-click gesture with no feedback is indistinguishable from a dead one, which is how this stayed
  invisible.
- **The light could never send the user back.** The direction was decided by asking which application
  was in front *at the instant of the click* — by which time the click had made the light's own process
  frontmost, so the answer was never DSH and a return click always went forward instead. The direction
  now comes from the last observed real application, and the light never records itself.
- **An acknowledgement expired one heartbeat after it was made.** `updatedAt` means "last heard from"
  — the heartbeat moves it every couple of seconds — and the renderer compared an acknowledgement
  against it as though it meant "when the state changed". Green therefore settled to grey and sprang
  back two seconds later, which looked like typing had undone it. The contract now carries
  **`changedAt`**, written only when a state is asserted and left alone by the heartbeat; the renderer
  compares against that, and falls back to noticing the transition itself for a publisher that
  predates the field.
- **`--print` never saw the frontmost application change.** It slept between polls, and `NSWorkspace`
  delivers that change as a notification on the run loop, so the process kept reporting whatever was
  in front when it started — the acknowledgement would have shipped as a feature that silently did
  nothing. Found by testing against a real application switch; the loop now pumps the run loop.

## [0.1.0] - 2026-10-02

Stage 1: the publisher. A DSH plugin that observes the agent lifecycle and writes one JSON document
to a fixed path, so a separate renderer can be built and tested without this plugin existing.

Contract version **1**.

### Added

- The state document at `~/Library/Application Support/dsh-status/state.json`: `version`, `state`,
  `sessionId`, `title`, `updatedAt`, `heartbeatMs`, `reason`, `meta`. Written atomically (temporary
  file plus rename) so a reader never sees a half-written document.
- Transitions: `unknown` on load and on dispose, `working` when a prompt is accepted, `waiting` when
  the turn is about to close.
- A heartbeat that re-stamps `updatedAt` on a fixed interval without changing the state, so a
  renderer can tell a live feed from a dead one — and a killed DSH cannot leave a light on.
- `meta` as the additive extension channel, with `meta.cwd` as its first tenant.
- Two test layers: the state machine against a purpose-built context (16 checks), and the mount plus
  waterfall delegation against the real cordis shipped with DSH Desktop (10 checks).

### Decisions

- **Root agent only.** `agent/turn-stopping` fires for subagents as well, because a child is a full
  agent with its own turns. Without the `parentSession` filter, a subagent finishing its turn would
  turn the light green while the user is still waiting.
- **`agent/pre-step` is always delegated.** It is a waterfall, and cordis vetoes the rest of the
  chain for any listener that does not call `next()`. Failing to delegate would stall every step.
- **The session identity is latched on every root event**, not only on `agent/created`: a hot
  patch-layer mount never sees that event, and the first state a user acts on must name its session.
- **No dependencies and no peer dependencies.** A `link:` install does not install a linked
  package's own dependencies, and a resolution failure inside a plugin can stop every profile from
  booting.
- **Writes never throw.** The first failure warns once, then goes quiet: a status indicator must not
  be able to fail the turn that triggered it.
- **Built on verified events.** `agent/status` appears in the harness documentation as a
  UI-driving event, but no emitter for it exists in any shipped bundle, so the publisher uses the
  four events confirmed in the agent loop.

### Known gaps at this version

- No live harness had driven the publisher when this version was cut; the mount and the event
  mapping were verified against the real framework, not against a running session.
- `title` is always `null`.
