# dsh-status

**Stage 1 of the DSH status light.** A DSH plugin that publishes the session's current state to
one small JSON file, so a native macOS indicator (stage 2) can draw it.

It reads nothing and draws nothing. The file is the entire interface between the two halves, which
is what lets each be built and tested while the other does not exist.

- **Stage 1 — this package.** Publisher.
- **Stage 2** — native renderer (`DSHLight.app`), reads the file, draws red/yellow/green.
- **Stage 3** — wiring: the plugin spawns and supervises the renderer.

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
| `state` | `unknown` \| `working` \| `waiting`. |
| `sessionId` | Session being reported on, or `null`. |
| `title` | Session title, or `null` (see *Known gaps*). |
| `updatedAt` | ms epoch. Re-stamped every `heartbeatMs` even when nothing changes. |
| `heartbeatMs` | The publisher's cadence, so the renderer need not hardcode a staleness rule. |
| `reason` | Which event caused this write: `init`, `session-start`, `prompt`, `turn-end`, `dispose`. Debugging only. |
| `meta` | **Extension channel.** Additive; unknown keys must be ignored by readers. |

**Renderer mapping**

| What the renderer sees | Light |
|---|---|
| file missing/unparseable, or `now - updatedAt > 3 × heartbeatMs` | 🔴 red |
| `state: "working"` | 🟡 yellow |
| `state: "waiting"` | 🟢 green |

**Extension rule (how future features land without breaking stage 2).** New information — latest
prompt cost, token counts, model name, a prompt preview for hover — goes into `meta`. New top-level
keys are only ever *added*. Nothing is renamed or removed. `version` changes only if a reader
written against the old shape would be wrong. `meta.cwd` is already there as the first tenant.

## Why the state machine looks like this

| Transition | Trigger | Why |
|---|---|---|
| → `unknown` | plugin load, and on dispose | Nothing known yet; and a disposed publisher must not keep claiming a session. |
| → `working` | `agent/pre-step` with a non-empty `messages` | The only verified signal that a prompt was actually accepted. The empty case is the ordinary between-steps pass and is ignored. |
| → `waiting` | `agent/turn-stopping` | The turn is about to close and is waiting on the user. |
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

## Verify stage 1

```bash
watch -n1 cat "$HOME/Library/Application Support/dsh-status/state.json"
```

Expected on a fresh session: `unknown`, then a prompt of yours makes it `working`, and the end of the
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
| `test/run.js` | The state machine: every transition, both subagent filters, the atomic writer, config fallback, heartbeat, dispose, and that an unwritable path warns once. 15 checks. | Nothing about cordis — it drives a purpose-built stub context. |
| `test/cordis.js` | The plugin **mounts into the real cordis** shipped with the app (`ctx.plugin`), and real `emit` / `waterfall` / `serial` reach the listeners. Critically, that `agent/pre-step` really delegates: cordis vetoes the rest of the chain for any listener that skips `next()`, so the inner fallback running is proof the agent step would not stall. Also: `ctx.effect` disposers run on fiber disposal, and a bad state path cannot break the mount. 10 checks. | No live agent turn drives it. Events are dispatched by hand, with payloads shaped the way `dsh-agent`'s `agentEvents` builds them. |

Both run against real files in a temp directory. Neither needs DSH, a network, or an API key.

## Known gaps

- **No live agent turn has driven this.** The event names, the `{ ...payload, agent }` fusion
  (`agentEvents` in `dsh-agent`), and the `parentSession` filter are verified from shipped source and
  from real child session logs — but the plugin has not run inside a booted harness, because mounting
  it requires restarting DSH. Expect a calibration pass on first install.
- `title` is always `null`. The session title plainly exists (the session log carries `session/title`
  events) but which accessor exposes it is unconfirmed, and a wrong guess would be worse than `null`.
  Fill it in when the renderer needs it.
- `agent/status` appears in the harness docs as a UI-driving event, but no emitter for it exists in
  any shipped bundle. Do not build on it until proven.
- One root agent is assumed. `agent/created` overwrites the recorded session, so a second concurrent
  root agent would make the light follow whichever spoke last.
