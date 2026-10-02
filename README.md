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
| `--style classic\|nostalgic` | appearance, overriding what was chosen last |
| `--ack-app BUNDLE-ID` | another application whose return to the front settles a green; repeatable |
| `--no-ack` | keep green until the next prompt instead of settling on return |
| `--level floating\|status\|screensaver` | how high the window sits, default `screensaver` |
| `--size POINTS` | dot diameter, default `24` |

The light sits on the **same material a menu uses**, so the right-click list reads as an extension of it
rather than a separate object. That also gives it a faint grey body on any wallpaper, and it follows light
and dark appearance on its own.

The light **docks to whichever screen border is nearest** when dropped, and remembers which one. That
border also decides the shape: lenses stack on a side edge and lie in a row along a top or bottom one, so
the light always grows *along* the border rather than across it. The right-click list opens flush to the
same border, hanging inward, so an edge-docked light never opens a menu off the edge of the screen.

**A drop near a corner keeps the direction it already had.** Around a corner the nearest border is a coin
toss, and changing the shape there is what used to resize the light half off the screen; only a drop
clear of a corner can turn it. Whatever happens, the final position is clamped inside the visible frame,
so no shape change can park the light out of reach.

```
Style
  ✓ Classic
    Nostalgic
─────────────
   (reserved for the next thing)
─────────────
Quit the light
```

The style persists between runs, with `--style` overriding it at launch. Orientation is not a setting at
all: it follows the border the light is docked to, so the two can never disagree. The separated group is
where the next feature goes, and a single menu column gives every row the same width for free.

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
npm test        # or: node test/run.js && node test/cordis.js
```

Two layers, deliberately separated because they prove different things:

| File | What it proves | What it cannot |
|---|---|---|
| `test/run.js` | The state machine: every transition, both subagent filters, the atomic writer, config fallback, heartbeat, dispose, a mid-turn mount latching its session, and that an unwritable path warns once. 16 checks. | Nothing about cordis — it drives a purpose-built stub context. |
| `test/cordis.js` | The plugin **mounts into the real cordis** shipped with the app (`ctx.plugin`), and real `emit` / `waterfall` / `serial` reach the listeners. Critically, that `agent/pre-step` really delegates: cordis vetoes the rest of the chain for any listener that skips `next()`, so the inner fallback running is proof the agent step would not stall. Also: `ctx.effect` disposers run on fiber disposal, and a bad state path cannot break the mount. 10 checks. | No live agent turn drives it. Events are dispatched by hand, with payloads shaped the way `dsh-agent`'s `agentEvents` builds them. |

Both run against real files in a temp directory. Neither needs DSH, a network, or an API key.

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
