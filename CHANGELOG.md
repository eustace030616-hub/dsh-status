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

### Planned

- **Stage 2 — a native macOS renderer.** A small `DSHLight.app` that reads the state document and
  draws red / yellow / green, with the state path as a launch argument so it can be developed
  against a fixture before this plugin is installed anywhere.
- **Stage 3 — wiring.** The plugin spawns the renderer and reaps it on dispose. This is the point at
  which the built binary must be added to the `files` allow-list, or installed copies will break
  while a source checkout keeps working.
- Session `title`, currently always `null`: the title exists in the session log, but which accessor
  exposes it is unconfirmed.
- A second root agent. `agent/created` overwrites the recorded session, so concurrent root agents
  would make the published state follow whichever spoke last.

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
