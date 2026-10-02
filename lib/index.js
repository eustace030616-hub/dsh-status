/**
 * dsh-status — publishes the root agents' turn state for a native indicator.
 *
 * One DSH process can drive several sessions at once, so a single state field
 * cannot say "one finished while another is still working". Every root session
 * keeps its own entry, the published `state` is the headline among them, and the
 * whole picture travels in `meta.sessions` so a renderer can aggregate for
 * itself.
 *
 * The renderer has to do that last step because only it knows what the user has
 * already read: an acknowledgement is a fact about the viewer, not about the
 * harness. So the publisher reports, and the renderer decides.
 *
 * Deliberate properties:
 * - **Root sessions only, for turn bookkeeping.** `agent/turn-stopping` fires for
 *   subagents too, and a child's turn end must not be read as a session's.
 * - **An ask is charged to the session that owns it.** A subagent blocked on an
 *   approval still needs the human, so it lands on its parent session rather
 *   than becoming a session of its own.
 * - **Never break a turn.** Every listener is wrapped, the writer swallows its
 *   own failures, and `agent/pre-step` always delegates to `next()`.
 * - **No dependencies at all** — see `config.js` for why.
 *
 * @module dsh-status
 */
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { resolveConfig } from './config.js'
import { API_KEY_REF, fetchBalance } from './balance.js'
import { buildDoc, createWriter } from './state.js'

/** The renderer that ships inside this package, so a plugin-page install needs
 *  no clone, no build and no toolchain. */
const RENDERER = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'bin',
  'DSHLight.app',
  'Contents',
  'MacOS',
  'DSHLight'
)

export const name = 'dsh-status'

/** No services are injected, and that is deliberate. The account balance reads
 *  the credential seam when the composition provides one, but declaring it here
 *  would make this plugin wait for a service that a custom composition may not
 *  have — and a plugin that never mounts is a worse failure than a missing
 *  balance. The seam is probed at request time instead; see `resolveKey`. */
export const inject = []

/** Which headline wins when sessions disagree. A blocked agent outranks
 *  everything, because it cannot proceed without the human. */
const PRIORITY = { asking: 3, waiting: 2, working: 1, idle: 0 }

/** How many sessions the snapshot carries. Beyond this a reader can show nothing
 *  useful, and the document should stay small. */
const SNAPSHOT_LIMIT = 8

/**
 * Whether an event belongs to a session the user is driving. A child agent
 * carries `parentSession`; a root does not, and a payload with no session is
 * never assumed to be one.
 */
function isRootAgent(agent) {
  const session = agent?.session
  if (session === null || session === undefined) return false
  return session.header?.parentSession === undefined
}

function sessionIdOf(agent) {
  const id = agent?.session?.id
  return typeof id === 'string' && id.length > 0 ? id : null
}

/**
 * Which session an ask belongs to. A subagent's approval is charged to its
 * parent, so answering it reads as unblocking that session.
 */
function askOwnerOf(agent) {
  const session = agent?.session
  return session?.header?.parentSession ?? sessionIdOf(agent) ?? 'unknown'
}

/** The session title is not confirmed to live in one place, so probe the
 *  plausible ones and prefer `null` over a guess. */
function titleOf(agent) {
  const session = agent?.session
  const title = session?.title ?? session?.header?.title
  return typeof title === 'string' && title.length > 0 ? title : null
}

function cwdOf(agent) {
  const cwd = agent?.session?.header?.cwd
  return typeof cwd === 'string' && cwd.length > 0 ? cwd : null
}

/**
 * Mount the publisher.
 *
 * @param {object} ctx - cordis context (`on`, `effect`, `logger`).
 * @param {unknown} config - optional `{ statePath, heartbeatMs, balance, balanceMs }`.
 */
export function apply(ctx, config = {}) {
  const { statePath, heartbeatMs, launch, lightArgs, balance, balanceMs } = resolveConfig(config)
  const write = createWriter(statePath, {
    onError: (error) => ctx.logger?.warn?.(`dsh-status: cannot write ${statePath}: ${String(error)}`)
  })

  /** id -> { state, reason, changedAt, title, cwd, pendingAsks, beforeAsk } */
  const sessions = new Map()
  let current = buildDoc({ state: 'idle', reason: 'init', heartbeatMs })
  let lastIdentity = null
  let lastChangedAt = null
  /** The last account block, or null before the first lookup lands. It rides in
   *  `meta.account` on every publish and every heartbeat after that. */
  let account = null
  /** The last reason the balance was unavailable, so a broken key is reported
   *  once rather than every few minutes. */
  let lastBalanceReason = null

  /** The entry for a session, created on first sight and refreshed from the
   *  agent whenever one is in hand. */
  function ensure(id, agent) {
    let entry = sessions.get(id)
    if (entry === undefined) {
      entry = {
        id,
        state: 'idle',
        reason: 'init',
        changedAt: Date.now(),
        title: null,
        cwd: null,
        pendingAsks: 0,
        beforeAsk: null
      }
      sessions.set(id, entry)
    }
    const title = titleOf(agent)
    if (title !== null) entry.title = title
    const cwd = cwdOf(agent)
    if (cwd !== null) entry.cwd = cwd
    return entry
  }

  /** Move one session, keeping its stamp when nothing actually moved: a reader's
   *  acknowledgement must not be undone by a repeat of the same state. */
  function setState(entry, state, reason) {
    if (entry.state !== state) {
      entry.state = state
      entry.changedAt = Date.now()
    }
    entry.reason = reason
  }

  /**
   * Recompute the headline across every session and publish it.
   *
   * The headline is the most urgent session, freshest among equals. It exists
   * for readers that understand only one state; everything else is in the
   * snapshot, so a renderer can weigh a finish against work it has already been
   * told about.
   */
  function publish(reason) {
    let best = null
    for (const entry of sessions.values()) {
      if (best === null) {
        best = entry
        continue
      }
      const delta = PRIORITY[entry.state] - PRIORITY[best.state]
      if (delta > 0 || (delta === 0 && entry.changedAt > best.changedAt)) best = entry
    }

    const state = best?.state ?? 'idle'
    const now = Date.now()
    // Identity is the headline's subject and state, not the reason: a repeat of
    // the same subject is not a new thing to tell the user about.
    const identity = `${state}|${best?.id ?? ''}`
    if (identity !== lastIdentity) {
      lastIdentity = identity
      lastChangedAt = now
    }

    const snapshot = [...sessions.values()]
      .sort((a, b) => PRIORITY[b.state] - PRIORITY[a.state] || b.changedAt - a.changedAt)
      .slice(0, SNAPSHOT_LIMIT)
      .map((entry) => ({
        id: entry.id,
        state: entry.state,
        reason: entry.reason,
        changedAt: entry.changedAt
      }))

    const meta = { sessions: snapshot }
    if (best?.cwd != null) meta.cwd = best.cwd
    // Additive inside `meta`, which is what the contract reserves for new
    // information: a reader that has never heard of an account ignores it.
    if (account !== null) meta.account = account

    current = buildDoc(
      {
        state,
        reason,
        sessionId: best?.id ?? null,
        title: best?.title ?? null,
        heartbeatMs,
        meta
      },
      now,
      lastChangedAt
    )
    write(current)
  }

  /** Re-stamp the current state so readers can tell a live feed from a dead one.
   *  This is what keeps a killed DSH from leaving a light on. */
  function heartbeat() {
    write({ ...current, updatedAt: Date.now() })
  }

  /** The renderer process, when this plugin is the one that started it. */
  let light = null

  function startLight() {
    if (!launch || process.platform !== 'darwin' || light !== null) return
    if (!existsSync(RENDERER)) {
      ctx.logger?.warn?.(`dsh-status: no renderer shipped at ${RENDERER}`)
      return
    }
    try {
      light = spawn(RENDERER, ['--state-file', statePath, ...lightArgs], { stdio: 'ignore' })
      // A light already running holds the exclusive lock and exits at once;
      // that is not an error, so neither handler escalates.
      light.on('error', (error) => {
        ctx.logger?.warn?.(`dsh-status: cannot start the renderer: ${String(error)}`)
        light = null
      })
      light.on('exit', () => {
        light = null
      })
      // The light is a convenience, never a reason for the harness to stay alive.
      light.unref?.()
    } catch (error) {
      ctx.logger?.warn?.(`dsh-status: cannot start the renderer: ${String(error)}`)
      light = null
    }
  }

  function stopLight() {
    if (light === null) return
    try {
      light.kill('SIGTERM')
    } catch {
      /* it may already be gone */
    }
    light = null
  }

  // MARK: the account

  /**
   * The API key, resolved through the harness's credential seam when the
   * composition has one, and from the ambient variable when it does not.
   *
   * Read with `ctx.get('credentials')`, which is cordis's way to reach a service
   * **without** the inject requirement and which answers `undefined` when the
   * composition mounts none. Direct property access reaches *only injected*
   * services, which is why the first version of this asked `ctx.credentials`,
   * got nothing every time, and reported "no api key configured" against a store
   * that had one. `ctx.get` is the difference between "the service is not there"
   * and "I never asked for it".
   *
   * The value is read here and handed straight to one request. It is never
   * stored, never logged, and never published — the document carries figures.
   */
  async function resolveKey() {
    try {
      const seam = typeof ctx.get === 'function' ? ctx.get('credentials') : ctx.credentials
      if (seam !== null && seam !== undefined && typeof seam.resolve === 'function') {
        const hit = await seam.resolve(API_KEY_REF)
        if (typeof hit?.value === 'string' && hit.value.length > 0) return hit.value
      }
    } catch {
      /* a seam that is absent, or that refuses to answer, is not an error here */
    }
    const ambient = process.env[API_KEY_REF]
    return typeof ambient === 'string' && ambient.length > 0 ? ambient : null
  }

  /**
   * One lookup, published into `meta.account`.
   *
   * Nothing about it reaches the state machine: the document's `state` is what
   * the light draws, and an account lookup that fails is not a dead feed. The
   * write is targeted rather than a `publish`, so the headline and its stamps
   * are left exactly as they were.
   */
  async function refreshBalance() {
    let block
    try {
      block = await fetchBalance({ key: await resolveKey() })
    } catch {
      // `fetchBalance` never throws; this is here so a future mistake inside it
      // cannot reach the state machine either.
      block = { at: Date.now(), reason: 'offline' }
    }

    const next = { fetchedAt: block.at, intervalMs: balanceMs }
    if (block.reason !== undefined) {
      next.reason = block.reason
    } else {
      next.isAvailable = block.isAvailable
      next.balances = block.balances
    }
    account = next
    current = { ...current, meta: { ...current.meta, account } }
    write(current)

    // Once per change of reason, not once per attempt: a key that is wrong is
    // wrong until it is fixed, and a warning every few minutes is noise.
    if (next.reason !== undefined) {
      if (next.reason !== lastBalanceReason) {
        lastBalanceReason = next.reason
        ctx.logger?.warn?.(`dsh-status: balance unavailable (${next.reason})`)
      }
    } else {
      lastBalanceReason = null
    }
  }

  publish('init')
  // After the first publish, so the renderer never has to draw a missing file.
  startLight()

  const timer = setInterval(heartbeat, heartbeatMs)
  timer.unref?.()

  // The first lookup is not awaited: mounting must not wait on the network, and
  // the light has nothing to do with the answer.
  let balanceTimer = null
  if (balance) {
    refreshBalance()
    balanceTimer = setInterval(refreshBalance, balanceMs)
    balanceTimer.unref?.()
  }

  ctx.effect(
    () => () => {
      clearInterval(timer)
      if (balanceTimer !== null) clearInterval(balanceTimer)
      // A disposed publisher must not keep claiming sessions it no longer
      // watches: a stale session id is worse than none.
      sessions.clear()
      stopLight()
      publish('dispose')
    },
    'dsh-status: heartbeat and final state'
  )

  ctx.on('agent/created', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      const entry = ensure(sessionIdOf(agent) ?? 'unknown', agent)
      setState(entry, 'idle', 'session-start')
      publish('session-start')
    } catch {
      /* a status publisher never fails a turn */
    }
  })

  // `agent/pre-step` is a waterfall: it must always be delegated, or the step
  // never opens. The empty case is the ordinary between-steps pass.
  ctx.on('agent/pre-step', ({ agent, messages }, next) => {
    try {
      if (isRootAgent(agent) && Array.isArray(messages) && messages.length > 0) {
        const entry = ensure(sessionIdOf(agent) ?? 'unknown', agent)
        setState(entry, 'working', 'prompt')
        publish('prompt')
      }
    } catch {
      /* ignored on purpose */
    }
    return typeof next === 'function' ? next() : undefined
  })

  ctx.on('agent/turn-stopping', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      const entry = ensure(sessionIdOf(agent) ?? 'unknown', agent)
      setState(entry, 'waiting', 'turn-end')
      publish('turn-end')
    } catch {
      /* ignored on purpose */
    }
  })

  ctx.on('agent/disposed', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      const id = sessionIdOf(agent)
      if (id !== null) sessions.delete(id)
      publish('dispose')
    } catch {
      /* ignored on purpose */
    }
  })

  // Blue: the agent is blocked on the human. Two seams reach the same state —
  // `approval/request` for a permission and `user-questions/request` for a
  // question — and both are waterfalls, so observing means publishing before
  // delegating and then returning whatever the real answerer decided.
  //
  // Deliberately *not* filtered to the root: a subagent blocked on an approval
  // still blocks its session, and the human is still the one who answers.
  function observeAsk(event, reason) {
    ctx.on(event, async (payload, next) => {
      let entry = null
      try {
        entry = ensure(askOwnerOf(payload?.agent), payload?.agent)
        entry.pendingAsks += 1
        if (entry.state !== 'asking') {
          entry.beforeAsk = entry.state
          setState(entry, 'asking', reason)
        }
        publish(reason)
      } catch {
        /* ignored on purpose */
      }
      try {
        return typeof next === 'function' ? await next() : undefined
      } finally {
        try {
          if (entry !== null) {
            entry.pendingAsks = Math.max(0, entry.pendingAsks - 1)
            // Only the last outstanding ask returns the session to work: several
            // interactions can be open at once.
            if (entry.pendingAsks === 0 && entry.state === 'asking') {
              setState(entry, entry.beforeAsk ?? 'working', 'answered')
              entry.beforeAsk = null
            }
            publish('answered')
          }
        } catch {
          /* ignored on purpose */
        }
      }
    })
  }

  observeAsk('approval/request', 'approval')
  observeAsk('user-questions/request', 'question')
}
