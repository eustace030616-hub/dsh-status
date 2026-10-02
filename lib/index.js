/**
 * dsh-status — publishes the root agent's turn state for a native indicator.
 *
 * Stage 1 of the DSH status light. Reads nothing, draws nothing: it observes
 * the agent lifecycle and writes one small JSON document (see `state.js`) that
 * a separate renderer polls. The file is the whole interface, so the renderer
 * can be built and tested against a hand-written fixture with no DSH running.
 *
 * Deliberate properties:
 * - **Root agent only.** `agent/turn-stopping` fires for subagents too, because
 *   a child is a full agent with its own turns. Without the `parentSession`
 *   filter a subagent finishing would turn the light green mid-turn.
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

/**
 * Whether an event belongs to the session the user is actually driving.
 * A child agent carries `parentSession`; the root does not. A payload with no
 * session is not assumed to be the root.
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
 * The session title is not yet confirmed to live in one place, so probe the
 * plausible ones and prefer `null` over a guess. Renderers must tolerate null.
 */
function titleOf(agent) {
  const session = agent?.session
  const title = session?.title ?? session?.header?.title
  return typeof title === 'string' && title.length > 0 ? title : null
}

/** `header.cwd` is recorded because it is verified to exist and it is the first
 *  tenant of `meta` — proving the extension channel end to end. */
function metaOf(agent) {
  const cwd = agent?.session?.header?.cwd
  return typeof cwd === 'string' && cwd.length > 0 ? { cwd } : {}
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

  let sessionId = null
  let title = null
  let current = buildDoc({ state: 'idle', reason: 'init', heartbeatMs })
  // The published identity, and when it was last asserted. Repeating the same
  // identity keeps `changedAt`, so a reader's acknowledgement cannot be undone
  // by the publisher re-asserting a state it already reported. The heartbeat
  // never touches `changedAt` either — that is the whole reason it exists.
  let lastIdentity = null
  let lastChangedAt = null

  /**
   * Latch the session identity, called on *every* root event rather than only
   * on `agent/created`. The plugin can be mounted after that event has already
   * fired for the live session — a hot patch-layer mount never sees it — and
   * the first state a user is likely to act on (`waiting`) must already carry
   * the session it refers to.
   */
  function remember(agent) {
    const id = sessionIdOf(agent)
    if (id !== null) sessionId = id
    const nextTitle = titleOf(agent)
    if (nextTitle !== null) title = nextTitle
  }

  /** Replace the state and publish it. */
  function publish(state, reason, meta) {
    const now = Date.now()
    const identity = `${state}|${reason}|${sessionId ?? ''}|${title ?? ''}`
    if (identity !== lastIdentity) {
      lastIdentity = identity
      lastChangedAt = now
    }
    current = buildDoc({ state, reason, sessionId, title, heartbeatMs, meta }, now, lastChangedAt)
    write(current)
  }

  /** Re-stamp the current state so readers can tell a live feed from a dead
   *  one. This is what keeps a killed DSH from leaving a permanent light on. */
  function heartbeat() {
    write({ ...current, updatedAt: Date.now() })
  }

  publish('idle', 'init')

  const timer = setInterval(heartbeat, heartbeatMs)
  timer.unref?.()

  ctx.effect(
    () => () => {
      clearInterval(timer)
      // A disposed publisher must not keep claiming a session it no longer
      // watches: a stale sessionId is worse than none, because the renderer
      // would offer to jump to a session the light is no longer reporting on.
      sessionId = null
      title = null
      publish('idle', 'dispose')
    },
    'dsh-status: heartbeat and final state'
  )

  ctx.on('agent/created', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      remember(agent)
      publish('idle', 'session-start', metaOf(agent))
    } catch {
      /* a status publisher never fails a turn */
    }
  })

  // `agent/pre-step` is a waterfall: it must always be delegated, or the step
  // never opens. The empty case is the ordinary between-steps pass.
  ctx.on('agent/pre-step', ({ agent, messages }, next) => {
    try {
      if (isRootAgent(agent) && Array.isArray(messages) && messages.length > 0) {
        remember(agent)
        publish('working', 'prompt', metaOf(agent))
      }
    } catch {
      /* ignored on purpose */
    }
    return typeof next === 'function' ? next() : undefined
  })

  ctx.on('agent/turn-stopping', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      remember(agent)
      publish('waiting', 'turn-end', metaOf(agent))
    } catch {
      /* ignored on purpose */
    }
  })

  // Blue: the agent is blocked on the human. Two seams reach the same state —
  // `approval/request` for a permission and `user-questions/request` for a
  // question — and both are waterfalls, so observing means publishing before
  // delegating and then returning whatever the real answerer decided.
  //
  // Deliberately *not* filtered to the root agent: a subagent blocked on an
  // approval still blocks the session, and the human is still the one who has
  // to answer. The root filter exists for turn bookkeeping, not for attention.
  let pendingAsks = 0

  function observeAsk(event, reason) {
    ctx.on(event, async (payload, next) => {
      pendingAsks += 1
      try {
        publish('asking', reason, metaOf(payload?.agent))
      } catch {
        /* ignored on purpose */
      }
      try {
        return typeof next === 'function' ? await next() : undefined
      } finally {
        pendingAsks -= 1
        try {
          // Only the last outstanding ask returns the light to work: several
          // interactions can be open at once.
          if (pendingAsks <= 0) {
            pendingAsks = 0
            if (current.state === 'asking') publish('working', 'answered', metaOf(payload?.agent))
          }
        } catch {
          /* ignored on purpose */
        }
      }
    })
  }

  observeAsk('approval/request', 'approval')
  observeAsk('user-questions/request', 'question')

  ctx.on('agent/disposed', ({ agent }) => {
    try {
      if (!isRootAgent(agent)) return
      sessionId = null
      title = null
      publish('idle', 'dispose')
    } catch {
      /* ignored on purpose */
    }
  })
}
