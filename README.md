# dsh-status

**A traffic light for DeepSeek Harness.** A DSH plugin publishes the session's current state to one
small JSON file; a native macOS dot reads it and shows red / yellow / green above every window.

The file is the entire interface between the two halves, which is what let each be built and tested
while the other did not exist.

- **The publisher.** `lib/` — a DSH plugin, installed from the plugin page.
- **The renderer.** `mac/` — `DSHLight.app`, universal and ad-hoc signed.
- **The wiring.** The plugin starts the renderer when it mounts and stops it on dispose. The built
  bundle ships inside the package (`bin/`), so a plugin-page install needs no clone and no toolchain.

## The contract

`~/Library/Application Support/dsh-status/state.json`

```json
{
  "version": 1,
  "state": "working",
  "sessionId": "session-83248b8c-3595-4b1d-b6f5-cb9b8cdfdc44",
  "title": null,
  "updatedAt": 1790000000000,
  "heartbeatMs": 2000,
  "reason": "prompt",
  "meta": { "cwd": "/Users/penghaoxi/workspace" }
}
```

| Field | Meaning |
|---|---|
| `version` | Contract version. Bumped **only** for a breaking change. |
| `state` | `idle` \| `working` \| `waiting` \| `asking`. |
| `sessionId` | Session being reported on, or `null`. |
| `title` | Session title, or `null` (see *Known gaps*). |
| `updatedAt` | ms epoch. **When the publisher was last heard from.** Re-stamped every `heartbeatMs` even when nothing changes — that is what makes staleness work, and why it must never be read as a change time. |
| `changedAt` | ms epoch. **When this state was last asserted.** Written on a publish and left alone by the heartbeat, so this — not `updatedAt` — is what an acknowledgement may be compared against. |
| `heartbeatMs` | The publisher's cadence, so the renderer need not hardcode a staleness rule. |
| `reason` | Which event caused this write: `init`, `session-start`, `prompt`, `turn-end`, `dispose`. Debugging only. |
| `meta` | **Extension channel.** Additive; unknown keys must be ignored by readers. |
| `meta.sessions` | Every session the publisher is watching: `{ id, state, reason, changedAt }`. The headline `state` above is the most urgent of them, for readers that understand only one. |
| `meta.account` | The account balance, when the publisher has one: `{ fetchedAt, intervalMs, isAvailable, balances: [{ currency, total, granted, toppedUp }] }`, or `{ fetchedAt, intervalMs, reason }` when the lookup failed. Figures are strings, as the provider sends them. Never carries a credential. |

**Renderer mapping**

| State | Lenses |
|---|---|
| rest (`idle`) | all three dark |
| a session is working | yellow lit |
| a session is blocked on you (`asking`) | **yellow breathing** — alive, not an alarm |
| an unread finish (`waiting`) | green lit |
| the feed cannot be trusted | red lit |

A broken feed outranks everything, because nothing else can be said about it. The split between red and
dark is the important one: **red means the feed itself cannot be trusted**, while dark means the feed is
healthy and nothing is pending. A reader that meets a state it has never heard of rests rather than
alarms, so adding one later cannot make an older renderer cry wolf.
**With several sessions** the publisher reports each one in `meta.sessions` and the renderer
aggregates, because only the renderer knows what you have already read:

| Condition | Light |
|---|---|
| any session `asking` | 🔵 blue — a blocked agent cannot proceed, so it outranks everything |
| any session `waiting` that you have not read | 🟢 green — *even while other sessions work*, so a finish is never swallowed by unrelated work |
| any session `working` | 🟡 yellow |
| otherwise | ⚪ grey |

So with one session finished and another still working you see green; once you have been back to DSH
and read the finish it turns **yellow, not grey**, because the other session is still busy. Each
session carries its own `changedAt`, so reading one finish cannot swallow a later one.

The split between red and grey is the important one. **Red means the feed itself cannot be trusted**
— the file is gone, unreadable or stale, so nothing can be said about the session. **Grey means the
feed is healthy and says nothing is pending.** A reader that meets a state it has never heard of
degrades to grey, never to red: adding a state later must not make older renderers cry wolf.

**Extension rule (how future features land without breaking stage 2).** New information — latest
prompt cost, token counts, model name, a prompt preview for hover — goes into `meta`. New top-level
keys are only ever *added*. Nothing is renamed or removed. `version` changes only if a reader
written against the old shape would be wrong. `meta.cwd` is already there as the first tenant.

The package version and the contract version move independently, and every change to the contract is
recorded in [CHANGELOG.md](CHANGELOG.md).

## Why the state machine looks like this

| Transition | Trigger | Why |
|---|---|---|
| → `idle` | plugin load, a session coming up or being switched to, and dispose | Rest. Nothing is pending, which is not a failure — and a disposed publisher must not keep claiming a session. Switching sessions is how a user acknowledges a green: the reminder has done its job. |
| → `working` | `agent/pre-step` with a non-empty `messages` | The only verified signal that a prompt was actually accepted. The empty case is the ordinary between-steps pass and is ignored. |
| → `waiting` | `agent/turn-stopping` | The turn is about to close and is waiting on the user. |
| → `asking` | `approval/request` or `user-questions/request` | The agent is blocked on a permission or a question. Both seams are waterfalls, so observing means publishing before delegating and returning the real answerer's result untouched. Deliberately **not** root-filtered: a subagent blocked on an approval still needs the human. Concurrent asks are counted, so the light stays blue until the last one is answered. |
| *(ignored)* | any of the above on a **subagent** | A child agent is a full agent with its own turns, so `turn-stopping` fires for it too. Without the `parentSession` filter, a subagent finishing flips the light green while you are still waiting. |

Two further safety properties:

- `agent/pre-step` is a **waterfall**. The listener always delegates to `next()`, so it can never
  stall a step, and every listener body is wrapped so a status bug cannot fail a turn.
- Writes are atomic (temp file + rename) and non-throwing: the first failure warns once and then
  goes quiet. A status indicator must never be able to break the agent.

## Configuration

Both keys are optional and validated by hand; any unusable value silently falls back to the default
(see `lib/config.js`).

| Key | Default | Notes |
|---|---|---|
| `statePath` | `~/Library/Application Support/dsh-status/state.json` | Must be absolute. |
| `heartbeatMs` | `2000` | Floor of 250. |
| `launch` | `true` | Start the renderer shipped in this package, and stop it on dispose. |
| `lightArgs` | `[]` | Extra renderer arguments — the way a browser-hosted DSH gets its `--open` and `--ack-app`. |
| `balance` | `true` | Look the account balance up and publish it in `meta.account`. This is the only request the package makes. |
| `balanceMs` | `300000` | How often. Floor of 60000. Slower than the heartbeat on purpose: an account is charged when a call is made, not second by second. |

## Install

### Preferred — the plugin page

Add the repository in DSH's plugin page (sidebar → **Plugins**). No clone, no YAML:

```
github:eustace030616-hub/dsh-status
```

`https://github.com/eustace030616-hub/dsh-status` works too. The manager normalises `github:` /
`gist:` / `git+` prefixes and pre-checks a github.com address with `git ls-remote` before pnpm runs.

Because the package declares `dsh.bundle`, the manager applies its overlay patch itself: the plugin
lands in the profile's `node_modules` and is mounted as a profile layer, so the row's
`name: 'dsh-status'` resolves as a real package. A package *without* `dsh.bundle` is installed as a
plain dependency with a warning — that warning is how you can tell auto-mount did not happen.

The renderer ships inside the same package, under `bin/`, and the plugin starts it for you. That is the
whole install: nothing to clone, nothing to build, nothing to launch.

**Then restart DSH Desktop.** The manager applies config changes live when HMR is available, but a
packaged Electron host gets only the config-watching subset (`dsh-desktop-hmr-fallback`) — it
explicitly does not reproduce module-level hot replacement, so a newly installed module needs a boot.
The restart also ends the session you are in.

### Fallback — clone and mount by path

For running the tests, iterating on the code, or when the git install is unavailable. The script backs
the patch file up first, refuses to run twice, and parses the result:

```bash
git clone https://github.com/eustace030616-hub/dsh-status.git ~/dsh-status
~/dsh-status/scripts/install.sh
```

That appends this row to
`~/Library/Application Support/dsh-desktop/harness/profiles/web/cordis.patch.yml` — **append, never
replace**; it is live config and a malformed patch can stop DSH from starting:

```yaml
- insert:
    - id: dsh-status
      name: '/absolute/path/to/dsh-status/lib/index.js'
```

`--print` shows the row without touching anything; `--uninstall` restores the newest backup.

> The plugin page is the path to prefer, and the path-valued `name` above is the one link not yet
> exercised in a live profile. This route also installs only what `files` names, so `scripts/` and
> `test/` exist in a clone but not in a package install — which is intended: the install script edits
> the profile patch layer by hand, and the plugin page does that properly.
>
> Keep the plugin dependency-free. A `link:` install does **not** install the linked package's own
> dependencies, and a resolution failure inside a plugin can stop every profile from booting — that
> is exactly the incident the desktop-pet bridge hit in its PR #104.

## Stage 2 — the renderer

`mac/` builds **DSHLight.app**: a three-lens traffic light. Three states used to compete for one bulb,
and grey had to carry "rest"; with three lenses there is a place for everything.

The plugin starts this for you when it mounts and stops it on dispose, so there is nothing to launch
by hand. Build it only when working on it, and after changing the Swift run `npm run ship` to refresh
the committed bundle in `bin/` — that copy is what an install actually runs. `npm test` fails if you
forget, because the shipped binary records the digest of the source it came from.

```bash
./mac/build.sh              # universal binary, ad-hoc signed, into ./build
npm run ship                # build, and refresh the bundle that ships in bin/
open build/DSHLight.app     # draw it by hand
pkill -f DSHLight           # stop it
```

To follow the light in a terminal instead — printed once, then only when it changes:

```bash
./mac/build.sh --run
```

| Flag | Effect |
|---|---|
| `--state-file PATH` | which document to read (default: the published path) |
| `--print` | follow in the terminal instead of drawing a window |
| `--interval SECONDS` | poll interval, default `0.25` |
| `--open PATH` | what a click opens, default `/Applications/DSH Desktop.app` |
| `--ack-app BUNDLE-ID` | another application whose return to the front settles a green; repeatable |
| `--no-ack` | keep green until the next prompt instead of settling on return |
| `--level floating\|status\|screensaver` | how high the window sits, default `screensaver` |
| `--size POINTS` | lens size for this run, overriding the size slider |

The light sits on the **same material a menu uses**, so the right-click list reads as an extension of it
rather than a separate object. That also gives it a faint grey body on any wallpaper, and it follows light
and dark appearance on its own. The body is **half the material's own strength** (`bodyOpacity`, 0.5) with a
**wash of black at 0.15 over it** (`bodyShade`), because the material is a light grey in light appearance and
read as too bright against a bright wallpaper. Darkening it rather than thinning it further is deliberate: a
fainter body dissolves into whatever is behind it, a darker one keeps its shape in both appearances. Neither
is a slider, and neither is the corner radius — the three parts of the look that are fixed rather than dialled.

The body and the light are **siblings, not parent and child**. They were nested until the body needed to be
fainter than opaque, and a view's alpha applies to everything inside it: the lenses would have faded along
with the square behind them. The body's corner radius is taken from its **narrow** side, so a tall light is
a rounded square — the radius used to come from the height, which was the narrow side back when the light
could lie down.

The light is a **traffic light**: three lenses stacked, red at the top. It has one shape, and it **docks to
whichever side of the screen is nearer** when dropped — left or right, remembered — sliding up and down
that side until it is dropped again. There is no horizontal mode: a row of lenses along the top edge was a
shape that had to be re-fitted every time the menu bar moved, which is one problem that only existed
because the shape did. The right-click list opens flush to the docked side, hanging inward, so an
edge-docked light never opens a list off the edge of the screen.

**The menu bar's height is held back, simply and always.** With "automatically hide and show the menu bar"
on, `visibleFrame` reports the whole screen whether the bar is up or down — 1680×1050 against a 1680×1050
frame here — so `NSStatusBar.thickness` is reserved instead, and a vertical light on a side edge is clamped
so its top can never reach the bar's strip. It is worth being plain about why it is reserved rather than
followed: measuring the bar's own window and moving the light with it was tried, and it produced a laggy
light that overlapped the bar it was following. A side-docked light has no business in the top strip, so
the strip is held back and the light is never underneath it.

```
Appearance ▸
Account    ▸
─────────────
Quit the light

Appearance ▸                    Account ▸
  Size   ●━━━━━━━━━━  20 pt       CNY ▸
  Gap    ●━━━━━━━━━━   8 pt         Total      12.62
  Rest   ●━━━━━━━━━━  28%           Granted     0.00
  Lit    ●━━━━━━━━━━  85%           Topped up  12.62
  ─────────────                   ─────────────
  Reset to default                Top up now
                                  updated 2m ago
```

**The list is a list of lists.** Almost everything worth putting in it is a thing with several numbers
inside — the light's own appearance, an account balance — so each of those is a folded group and the first
level stays down to what the light can say at a glance. Everything is folded by default, and the values
inside are whatever the light is wearing now.

**The light is four numbers, and the appearance group is where they are set.** One slider each for the
size of a lens, the gap between the lenses, and how solid a resting and a lit lens are, and a `Reset to
default` row beneath them — four sliders with no way back is a one-way door, and the values a fresh install
wears are not something anyone should have to remember. The reset is one assignment through the same path a
slider takes, so the window is re-fitted and the change is remembered exactly as a drag would be. Every slider
applies **as it is dragged** — the window is re-fitted and re-anchored on each step, so the light on screen
is the preview rather than a change that lands when the list closes. The values are remembered between
runs, and `--size` overrides the size slider for a single run.

A slider is a real control in a menu row, not a label: the row is a small view holding a hand-drawn knob,
because the one event a menu is documented to push into a view it hosts is the mouse, while a stock
`NSSlider` pulls its own drags out of the event queue instead. The knob snaps to whole points and whole
percents, so it can always reach the number the readout prints. While the list is open the light drops a
level, below the menu, so a lens growing under a row cannot take the clicks meant for it.

**The account is a plugin of its own, and that is the point of it.** It declares `inject: ['credentials']`,
and an unsatisfied `inject` leaves a plugin waiting rather than failing — so a composition with no credential
service loses the balance and keeps the light. Declaring the same dependency on the publisher would have made
the light wait with it, which is the one outcome this project cannot accept.

**The account group is real, and filling it is the plugin's work rather than the renderer's.** The
publisher makes one authenticated `GET https://api.deepseek.com/user/balance` every `balanceMs` and puts the
answer in `meta.account`; the renderer draws whatever it finds there — one folded group per currency that
actually holds something, with `Top up now` and a footer saying how old the answer is. The endpoint answers in
every currency the account has ever touched, so a currency sitting at zero is a row that says nothing and is
not listed; a figure that cannot be read is *not* treated as zero, because an unreadable amount should be
shown rather than hidden. `Top up now` opens the platform's own top-up page — the destination DSH's account
service publishes for the same purpose, not a URL invented here — and it is offered whether or not the balance
could be read. The renderer
holds no key and makes no requests, which is why a balance it cannot read is a dim reason rather than a
number it guessed:

```
Account ▸
  CNY ▸
    Total      12.76
    Granted     0.00
    Topped up  12.76
  ─────────────
  Top up now
  updated 3m ago
```

A failure is a **code, not a message** — `no-key`, `unauthorized`, `offline`, `timeout`, `http-503`,
`bad-body` — shown as a sentence in that footer, and logged once per change of reason rather than once per
attempt. A failure is retried in fifteen seconds and doubles from there up to `balanceMs`, because a single
transient miss used to cost a whole blank period. Figures already published are **kept** when a later lookup
fails: they are still the last thing that was true, so the list shows them with their real age and the reason
they have stopped moving. DeepSeek's own 401 quotes part of the key it rejected, so a response body is read only when the
answer was a good one and dropped otherwise; see [Secrets](#secrets).

An account lookup **never touches `state`**. Red stays reserved for a feed that cannot be trusted, so an
account that cannot be read is a row in a list and never a lens. `is_available: false` — not enough balance
for API calls — is a row too, for the same reason: the bulbs answer for the agent, not for the account. A
stale feed is still drawn, because the last figures it was given are worth showing next to how old they are.

There is no highlight on the lenses, and no glass in them: a flat disc with a ring. A white highlight in the
upper left was tried and asked away — at this size it was the busiest thing on the screen. The ring is a light
grey (`rimGrey`, 0.45) rather than black, at an opacity left exactly where the black one had it (`rimAlpha`,
0.45): black at this size drew a hard edge the eye went to before the lens it was outlining. Measured from a
rendered lens over white, the ring reads 0.805 where a black one would read 0.550, against a resting disc at
0.918.

Three properties worth keeping:

- **It only ever reads.** Nothing in the renderer writes to the state file, so it cannot disturb the
  publisher or the session.
- **A dead feed is red, not the last colour.** The heartbeat is what makes that possible — without
  it, a killed DSH would leave a green light claiming the agent had finished.
- **Rest is grey, not red.** Red is reserved for a feed that cannot be trusted, so it stays rare and
  keeps its meaning. A fresh boot, a switch to a session that has no agent yet, or a state this build
  has not learned yet are all rest, and the reminder green is what stands out because nothing else
  competes with it.
- **The gesture is a double-click, and it only navigates.** Whatever colour is showing, it switches
  between DSH and the application you came from — forward when DSH is not in front, back when it is.
  The colour answers *"should I go?"*; the click does the going, so you never have to read the light to
  know what a click will do. A single click is inert — it only draws a ring, so the gesture is visible
  while it waits for its partner — and when there is nowhere to return to it says so rather than
  silently doing nothing.
- **Aggregation is the renderer's job.** The publisher reports every session and stops there; whether
  a green has been read is a fact about the viewer, not about the harness, so the last step can only
  happen where the eyes are. That is why `meta.sessions` exists and why the headline `state` is only a
  convenience for simple readers.
- **One light only.** The renderer takes an exclusive `flock` for the life of its process, so the
  plugin's instance and a hand-launched one cannot both draw. A lock that cannot even be *opened* is not
  contention, so the light runs without one and says why — refusing to draw would be worse than a
  possible duplicate.
- **Being in DSH is what acknowledges.** The reminder exists to bring you here, so while you are here it
  has nothing left to do: green settles the moment DSH is in front, not only when you arrive from
  somewhere else. That also covers a finish landing while you are already looking at DSH, which a
  transition test could never see. The click therefore needs to know nothing about state, and the
  reminder cannot be left hanging by a gesture that forgot to clear it.
- **It restores the application, not the window or tab.** That is as far as public API reaches: macOS
  will not let one application select another's window or browser tab. In practice it is what "back to
  my work" means — VSCode returns to the window being edited, the browser to the tab being read.
  Neither DSH nor the light itself is ever remembered, since returning to either would be a no-op.
- **Green retires itself while you are there.** The publisher cannot know this: switching between
  live sessions emits no agent event at all — verified by recording the state file across a switch,
  which showed the heartbeat ticking and *nothing* else being written. So the acknowledgement lives
  on the Mac, where the frontmost window is visible. It is stored in `UserDefaults`, shared by both
  modes, and compared against the finish's `changedAt` — a newer finish is green again rather than
  being suppressed by an older acknowledgement. Against `updatedAt` it would expire on the next
  heartbeat, which is exactly the bug this field exists to fix. A publisher too old to send
  `changedAt` is handled by the renderer noticing the finish itself. If you drive DSH in a browser rather than the desktop
  app, add its bundle identifier: `--ack-app com.apple.Safari`, knowing that any return to Safari
  then counts as a return to DSH.
- **No Apple account is needed.** The bundle is ad-hoc signed, which is enough for the kernel, and a
  package-manager install does not set the quarantine flag, so Gatekeeper is not in the path either.

> **Point it at whatever actually shows your DSH.** If you drive DSH in a browser rather than the
> desktop app, the click and the return-to-DSH acknowledgement both need to know that:
>
> ```bash
> open build/DSHLight.app --args --open /Applications/Safari.app --ack-app com.apple.Safari
> ```
>
> Otherwise the light sends you to the desktop app while you are working in a tab, and never notices
> you coming back. `--ack-app` is repeatable if you use more than one.

`mac/` is deliberately **not** in the package's `files`: at stage 3 the plugin will spawn the built
binary, and that is the moment the binary has to ship with the package.

## Verify stage 1

```bash
cat "$HOME/Library/Application Support/dsh-status/state.json"
```

To watch transitions rather than the 2 s heartbeat — this prints only when `state` or `reason`
changes, and needs nothing installed:

```bash
S="$HOME/Library/Application Support/dsh-status/state.json"
last=""
while true; do
  cur=$(python3 -c "import json;d=json.load(open('$S'));print(d['state'],d['reason'])" 2>/dev/null)
  [ "$cur" != "$last" ] && printf '%s  %s\n' "$(date +%H:%M:%S)" "$cur"
  last="$cur"
  sleep 0.5
done
```

> `watch` is a Linux tool and is not shipped with macOS — `brew install watch` if you want it.

Expected on a fresh session: `idle` (grey), then a prompt of yours makes it `working`, and the end of the
turn makes it `waiting`. `reason` tells you which event wrote each line. If the state never changes,
the plugin is not mounted (`reason` will be stuck at `init` from a stale file, or the file will not
exist) — check `~/Library/Logs/DSH Desktop/harness.log` for a loader warning.

## Test

```bash
npm test        # or: node test/run.js && node test/balance.js && node test/cordis.js
```

Two layers, deliberately separated because they prove different things:

| File | What it proves | What it cannot |
|---|---|---|
| `test/run.js` | The state machine: every transition, both subagent filters, the atomic writer, config fallback, heartbeat, dispose, a mid-turn mount latching its session, that an unwritable path warns once, and the account block: published, carried through a heartbeat, refused without moving the light, and off when switched off. 29 checks. | Nothing about cordis — it drives a purpose-built stub context. |
| `test/balance.js` | The balance fetcher against every answer the endpoint can give: figures, a refused key, a server error, a dead connection, a timeout, and a body that cannot be read. It also asserts the key never appears in what comes back. 13 checks, no network and no key. | Nothing about the plugin around it — the `fetch` is handed in. |
| `test/cordis.js` | The plugin **mounts into the real cordis** shipped with the app (`ctx.plugin`), and real `emit` / `waterfall` / `serial` reach the listeners. Critically, that `agent/pre-step` really delegates: cordis vetoes the rest of the chain for any listener that skips `next()`, so the inner fallback running is proof the agent step would not stall. Also: `ctx.effect` disposers run on fiber disposal, and a bad state path cannot break the mount. 11 checks. | No live agent turn drives it. Events are dispatched by hand, with payloads shaped the way `dsh-agent`'s `agentEvents` builds them. |

Both run against real files in a temp directory. Neither needs DSH, a network, or an API key.

## Secrets

This project never handles the API key. The plugin knows the **name** `DEEPSEEK_API_KEY` and nothing else:

- **The value is resolved at request time** through the harness's credential seam and lives in one local for
  the length of one request. Nothing stores it, and a rotated key reaches the next request with no restart.
  The seam arrives by **`inject`**, which is the only route that works: plain property access reaches only
  services a plugin has declared, and `ctx.get` answers `undefined` outside the realm that provides one. Two
  versions of this package learned that the hard way, in that order.
- **Existence is asked with `describe()`**, which reports `{configured, source}` and by design never
  returns the value. Any surface that only needs to know *whether* a key is set uses that one.
- **The published document is plain JSON on disk.** Numbers go in it; the key never does. The renderer is
  a reader with no network and no credentials, and it receives figures rather than secrets.
- **Error bodies are not kept.** DeepSeek's own 401 echoes part of the key it rejected — `your api key:
  ****abcd is invalid` — so a failure is mapped to a code such as `unauthorized` or `offline`, and the
  body is dropped rather than logged. (The fragment above is a placeholder, deliberately: writing a real
  one into this file would be the very mistake the section is about.)
- **The key is never passed to a child process.** Process arguments are readable by anything running as
  the same user (`ps`), which is why the renderer is handed a file and not a credential.
- **Tests inject the resolver and the HTTP client**, hand them a canary secret, and assert the canary
  appears nowhere: not in the published document, not in a log line, not in `process.argv`. That is what
  makes "the key stays out" a test rather than a promise.

The same rule applies to working on it, which is the part that actually gets forgotten: **never print a
credential value** — not out of the store, not out of a config file, not out of an error message. Inspect
a credentials file with every value masked, and describe one by existence, source and length. When a
value is genuinely needed, read and use it inside the single process that needs it, so it never reaches
command arguments or output. If one does escape, say so plainly and rotate it through the seam
(`ctx.credentials.set(ref, …)`) rather than trying to scrub the transcript.

## Known gaps

- **The prompt → `working` path is confirmed live; the turn end is not.** Installing through the
  plugin page and sending a prompt produced `state: "working"`, `reason: "prompt"`, a `sessionId`
  matching the live session, `meta.cwd` matching its workspace, an advancing heartbeat, no `.tmp`
  residue and no warnings in the harness log — so `agent/pre-step`, the root-agent filter and the
  writer behave as designed in a real harness. The `turn-end` → `waiting` write has **not** been
  observed, because the next turn's prompt overwrites it before it can be read; watch the file in the
  gap between turns to confirm it.
- `title` is always `null`. The session title plainly exists (the session log carries `session/title`
  events) but which accessor exposes it is unconfirmed, and a wrong guess would be worse than `null`.
  Fill it in when the renderer needs it.
- `agent/status` appears in the harness docs as a UI-driving event, but no emitter for it exists in
  any shipped bundle. Do not build on it until proven.
- One root agent is assumed. `agent/created` overwrites the recorded session, so a second concurrent
  root agent would make the light follow whichever spoke last.
