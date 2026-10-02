# traffic light

**A DSH plugin and a macOS light daemon.** The plugin publishes what every session is doing to one small
JSON file; the daemon reads that file and draws a traffic light above every window. Two processes, one
document, no socket between them.

- **The plugin.** `lib/` — a DSH plugin, installed from the plugin page.
- **The daemon.** `mac/` — `DSHLight.app`, universal and ad-hoc signed. It only ever reads.

## Install

**The plugin** — paste this into DSH's plugin page (sidebar → **Plugins**) and restart DSH:

```
github:eustace030616-hub/traffic-light
```

**The daemon** — nothing to install: it ships inside the same package and the plugin starts it. To run it on
its own, clone and open the shipped bundle:

```bash
git clone https://github.com/eustace030616-hub/traffic-light.git ~/traffic-light
open ~/traffic-light/bin/DSHLight.app
```

## Usage

| You see | It means |
|---|---|
| **dark** | rest (`idle`): nothing is pending, which is not a failure |
| **yellow, steady** | a session is working (`working`) |
| **yellow, pulsing** | a session is blocked on you (`asking`) — 30% → 100% over 1.3 s |
| **green** | a turn finished and you have not read it (`waiting`) |
| **red** | the feed itself cannot be trusted — gone, unreadable or stale |

| You do | It does |
|---|---|
| **double-click** | switch between DSH and the application you came from |
| **right-click** | open the list: `Appearance`, `Account`, `Quit the light` |
| **drag** | dock to the nearer screen edge, at whatever height you drop it |
| **single click** | nothing, on purpose — it only shows the click arrived |

A green settles by itself while DSH is in front, because being here is what the reminder was asking for.

```
Appearance ▸                    Account ▸
  Size   ●━━━━━━━━━━  20 pt       CNY          12.62
  Gap    ●━━━━━━━━━━   8 pt       ─────────────
  Rest   ●━━━━━━━━━━  28%         Top up now
  Lit    ●━━━━━━━━━━  85%         updated 2m ago
  ─────────────
  Reset to default
```

The sliders apply as they are dragged and are remembered; `Reset to default` restores 20 / 8 / 28% / 85%.
The account is one line per currency that holds something, with the platform's own top-up page below it.

## How the data moves

One file, one direction:

```
DSH Desktop                                  the daemon (DSHLight)
  agent/pre-step       a prompt was accepted   reads the document every 0.25 s
  agent/turn-stopping  the ordinary turn end   never writes, never fetches,
  agent/status         idle | running          holds no credential
  approval/request     blocked on you
  user-questions/…     blocked on you
        │                                             ▲
        ▼                                             │
  lib/index.js — one document per change, and the     │
  same document re-stamped every 2 s (the heartbeat)  │
        │                                             │
        ▼                                             │
  ~/Library/Application Support/dsh-status/state.json ┘
        written to a temp file and renamed into place
```

- **Many sessions, one light.** Every root session travels in `meta.sessions`; the daemon aggregates
  blocked > unread finish > working > rest.
- **Several harnesses: not yet.** Each publisher writes the whole document, so two would overwrite each
  other, and the daemon is a singleton (`flock`) reading one path. A lock per path is what would have to
  move first.
- **Anything else that speaks the contract:** write the document yourself, keep `updatedAt` fresh, point the
  daemon at it with `--state-file PATH`. No code in the daemon changes.

## The document

`~/Library/Application Support/dsh-status/state.json` — `cat` it, or follow it with `DSHLight --print`.

```json
{ "version": 1, "state": "working", "sessionId": "session-1a2b3c4d", "title": null,
  "updatedAt": 1790000000000, "changedAt": 1790000000000, "heartbeatMs": 2000,
  "reason": "prompt", "meta": { "cwd": "/Users/you/project" } }
```

| Field | Meaning |
|---|---|
| `version` | Contract version. Bumped **only** for a breaking change. |
| `state` | `idle` \| `working` \| `waiting` \| `asking`. |
| `sessionId` | Session being reported on, or `null`. |
| `title` | Session title — always `null` for now (see *Known gaps*). |
| `updatedAt` | When the publisher was last heard from. Re-stamped every `heartbeatMs` even when nothing changes — that is what makes staleness work, and why it must never be read as a change time. |
| `changedAt` | When this state was last asserted. The heartbeat leaves it alone, so this — not `updatedAt` — is what an acknowledgement may be compared against. |
| `heartbeatMs` | The publisher's cadence, so the daemon need not hardcode a staleness rule. |
| `reason` | Which event wrote this: `init`, `session-start`, `prompt`, `turn-end`, `agent-idle`, `agent-running`, `approval`, `question`, `answered`, `dispose`. Debugging only. |
| `meta` | Extension channel: additive, and unknown keys must be ignored. |
| `meta.sessions` | Every session the publisher watches: `{ id, state, reason, changedAt }`. |
| `meta.account` | `{ fetchedAt, intervalMs, isAvailable, balances: [{ currency, total, granted, toppedUp }] }`, or a `reason` when the lookup failed. Figures are strings; never a credential. |

New information goes into `meta`, keys are only ever added, and a reader that meets a state it has never
heard of rests rather than alarms — so a new state or key cannot make an older build cry wolf.

## What moves the light

| Transition | Trigger |
|---|---|
| → `idle` | plugin load, a session coming up, dispose |
| → `working` | `agent/pre-step` with messages, or `agent/status: running` |
| → `waiting` | `agent/turn-stopping`, or `agent/status: idle` |
| → `asking` | `approval/request` or `user-questions/request`, counted until the last is answered |
| ignored | any of the above on a subagent; an ask is charged to its parent session |

Only the agent's status covers every ending: a turn you **stop** is aborted, and `turn-stopping` is never
dispatched for it — which is why a stopped session used to keep the light yellow until DSH restarted.

## Configuration

Every key is optional and validated by hand; an unusable value falls back to the default (`lib/config.js`).

| Key | Default | Notes |
|---|---|---|
| `statePath` | `~/Library/Application Support/dsh-status/state.json` | must be absolute |
| `heartbeatMs` | `2000` | floor of 250 |
| `launch` | `true` | start the daemon on mount, stop it on dispose |
| `lightArgs` | `[]` | extra daemon arguments, e.g. `--open` / `--ack-app` for a browser-hosted DSH |
| `balance` | `true` | the only request this package makes |
| `balanceMs` | `300000` | floor of 60000 |

## The daemon

```bash
npm test                  # 64 checks — no DSH, no network, no key
npm run ship              # rebuild bin/ from the Swift (npm test fails if it drifts)
./mac/build.sh --run      # follow the light in a terminal
open build/DSHLight.app   # draw it by hand
pkill -f DSHLight         # stop it
```

| Flag | Effect |
|---|---|
| `--state-file PATH` | which document to read (default: the published path) |
| `--print` | follow in the terminal instead of drawing a window |
| `--interval SECONDS` | poll interval, default `0.25` |
| `--open PATH` | what the double-click opens, default `/Applications/DSH Desktop.app` |
| `--ack-app BUNDLE-ID` | another application whose return settles a green; repeatable |
| `--no-ack` | keep green until the next prompt instead of settling on return |
| `--level floating\|status\|screensaver` | how high the window sits, default `screensaver` |
| `--size POINTS` | lens size for this run, overriding the size slider |

Worth knowing:

- The body is the **menu's own material at half strength**, with a 0.15 black wash and a corner radius
  taken from its narrow side; the ring around a lens is light grey, never black.
- The **menu bar's 22 points are always reserved**, never followed: `visibleFrame` reports the whole screen
  in both bar states, and riding the bar produced a laggy light that overlapped it.
- **Red is the feed, never the session.** A balance that cannot be read is a dim row in the list, never a lens.
- The daemon **holds no key and makes no requests**; every account figure comes from the publisher.
- **One light per user** — an exclusive `flock` for the life of the process.
- The double-click **restores the application, not the window or tab** — as far as public API reaches.
- **No Apple account is needed**: ad-hoc signed, and a package-manager install sets no quarantine flag.

## Secrets

- The API key is resolved at request time through the harness's credential seam — `inject` is the only
  route that works — and lives in one local for the length of one request. Nothing stores it, and a rotated
  key reaches the next request with no restart.
- A failure is a **code, never the provider's message**: DeepSeek's own 401 echoes part of the key it
  rejected, so a response body is read only when the answer was a good one.
- The key never reaches the published document, a log line, or a child process's arguments, and the daemon
  has no credential at all. The tests inject a canary and assert it appears nowhere.
- Working on it, the same rule: never print a credential. Describe one by existence, source and length, and
  rotate through `ctx.credentials.set(ref, …)` if one escapes.

## Known gaps

- `title` is always `null`: the session title plainly exists, but which accessor exposes it is unconfirmed,
  and a wrong guess would be worse than `null`.

MIT — see [LICENSE](LICENSE).
