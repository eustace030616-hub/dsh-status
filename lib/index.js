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
import { resolveConfig } from './config.js'
import { buildDoc, createWriter } from './state.js'

export const name = 'dsh-status'

/** No services are injected: this plugin only listens and writes files. */
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
 * @param {unknown} config - optional `{ statePath, heartbeatMs }`.
 */
export function apply(ctx, config = {}) {
  const { statePath, heartbeatMs } = resolveConfig(config)
  const write = createWriter(statePath, {
    onError: (error) => ctx.logger?.warn?.(`dsh-status: cannot write ${statePath}: ${String(error)}`)
  })

  /** id -> { state, reason, changedAt, title, cwd, pendingAsks, beforeAsk } */
  const sessions = new Map()
  let current = buildDoc({ state: 'idle', reason: 'init', heartbeatMs })
  let lastIdentity = null
  let lastChangedAt = null

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

  publish('init')

  const timer = setInterval(heartbeat, heartbeatMs)
  timer.unref?.()

  ctx.effect(
    () => () => {
      clearInterval(timer)
      // A disposed publisher must not keep claiming sessions it no longer
      // watches: a stale session id is worse than none.
      sessions.clear()
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
