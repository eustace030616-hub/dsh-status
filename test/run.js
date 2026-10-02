/**
 * State-machine self-test: no DSH, no test framework, no dependencies.
 *
 * A fake cordis context hands us the listeners `apply` registers, so the whole
 * state machine is exercised against a real file on disk in a temp directory.
 * Run with `npm test` (or `node test/run.js`).
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { DEFAULTS, resolveConfig } from '../lib/config.js'
import { apply } from '../lib/index.js'

const root = mkdtempSync(join(tmpdir(), 'dsh-status-test-'))
const warnings = []

/**
 * A fake cordis context that records listeners and disposers.
 *
 * It emulates injection, because that is the part that broke in the real
 * harness: a service reaches a child plugin only through `inject`, a child whose
 * dependencies are missing is never applied, and the service appears on the
 * child's context and not on the parent's. A stub that handed the service to
 * everyone would keep passing while the harness failed.
 *
 * @param {object} [services] - services this composition provides, by name.
 */
function makeCtx(services = {}) {
  const handlers = new Map()
  const disposers = []
  const ctx = {
    logger: { warn: (message) => warnings.push(String(message)) },
    on: (event, handler) => handlers.set(event, handler),
    effect: (callback) => disposers.push(callback()),
    plugin: (mod, config = {}) => {
      const apply = typeof mod === 'function' ? mod : mod?.apply
      const needs = (typeof mod === 'function' ? mod.inject : mod?.inject) ?? []
      const missing = needs.filter((name) => services[name] === undefined)
      if (missing.length === 0 && typeof apply === 'function') {
        const child = { ...ctx, ...Object.fromEntries(needs.map((name) => [name, services[name]])) }
        apply(child, config)
      }
      return { dispose() {} }
    }
  }
  return { ctx, handlers, disposers }
}

const ROOT = { session: { id: 'session-root', header: { cwd: '/tmp/project' } } }
const CHILD = {
  session: { id: 'session-child', header: { parentSession: 'session-root', cwd: '/tmp/project' } }
}
const NO_SESSION = {}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

let passed = 0
let failed = 0
async function check(label, fn) {
  try {
    await fn()
    passed += 1
    console.log(`  ok   ${label}`)
  } catch (error) {
    failed += 1
    console.log(`  FAIL ${label}\n         ${error.message}`)
  }
}

/** Fire a listener the way the harness would, with a delegating `next`. */
function fire(harness, event, payload) {
  const handler = harness.handlers.get(event)
  assert.ok(handler, `no listener registered for ${event}`)
  return handler(payload, () => Promise.resolve('delegated'))
}

const statePath = join(root, 'nested', 'state.json')
const read = () => JSON.parse(readFileSync(statePath, 'utf8'))

console.log('dsh-status — the state machine\n')

await check('the shipped renderer was built from the Swift source beside it', () => {
  const source = readFileSync(new URL('../mac/Sources/DSHLight.swift', import.meta.url))
  const digest = createHash('sha256').update(source).digest('hex')
  const recorded = readFileSync(new URL('../bin/SOURCE-SHA256', import.meta.url), 'utf8').trim()
  assert.equal(recorded, digest, 'bin/ is stale — run scripts/ship.sh')
  assert.ok(
    existsSync(new URL('../bin/DSHLight.app/Contents/MacOS/DSHLight', import.meta.url)),
    'the shipped bundle has no executable'
  )
})

await check('config: unusable values fall back to the defaults', () => {
  assert.equal(resolveConfig(undefined).statePath, DEFAULTS.statePath)
  assert.equal(resolveConfig({ statePath: 'relative/path.json' }).statePath, DEFAULTS.statePath)
  assert.equal(resolveConfig({ heartbeatMs: 10 }).heartbeatMs, DEFAULTS.heartbeatMs)
  assert.equal(resolveConfig({ heartbeatMs: 1.5 }).heartbeatMs, DEFAULTS.heartbeatMs)
  assert.equal(resolveConfig({ statePath: '/tmp/x.json', heartbeatMs: 500 }).statePath, '/tmp/x.json')
  assert.equal(resolveConfig(null).statePath, DEFAULTS.statePath)
})

const main = makeCtx()
// A long heartbeat isolates the state-machine assertions from re-stamping.
apply(main.ctx, { statePath, heartbeatMs: 60000, launch: false, balance: false })

await check('init: publishes idle, creates the directory, writes a full document', () => {
  assert.ok(existsSync(statePath), 'state file was not created')
  const doc = read()
  assert.equal(doc.version, 1)
  assert.equal(doc.state, 'idle')
  assert.equal(doc.reason, 'init')
  assert.equal(doc.sessionId, null)
  assert.equal(doc.title, null)
  assert.equal(doc.heartbeatMs, 60000)
  assert.deepEqual(doc.meta.sessions, [])
  assert.ok(Number.isFinite(doc.updatedAt))
})

await check('writer: is atomic — no temporary file survives a write', () => {
  assert.deepEqual(readdirSync(join(root, 'nested')), ['state.json'])
})

await check('agent/created (root): records the session, stays idle', async () => {
  await fire(main, 'agent/created', { agent: ROOT })
  const doc = read()
  assert.equal(doc.state, 'idle')
  assert.equal(doc.reason, 'session-start')
  assert.equal(doc.sessionId, 'session-root')
  assert.equal(doc.meta.cwd, '/tmp/project')
  assert.ok(Array.isArray(doc.meta.sessions) && doc.meta.sessions.length >= 1)
})

await check('agent/pre-step (root, prompt): working, and the waterfall is delegated', async () => {
  let delegated = false
  const handler = main.handlers.get('agent/pre-step')
  handler({ agent: ROOT, messages: [{ role: 'user' }] }, () => {
    delegated = true
    return Promise.resolve('delegated')
  })
  const doc = read()
  assert.equal(doc.state, 'working')
  assert.equal(doc.reason, 'prompt')
  assert.equal(doc.sessionId, 'session-root')
  assert.ok(delegated, 'next() was not called — this would stall the agent step')
})

await check('agent/pre-step (root, no messages): the between-steps pass is ignored', async () => {
  await fire(main, 'agent/pre-step', { agent: ROOT, messages: [] })
  const doc = read()
  assert.equal(doc.state, 'working')
  assert.equal(doc.reason, 'prompt')
})

await check('agent/pre-step (missing session): not assumed to be the root', async () => {
  await fire(main, 'agent/pre-step', { agent: NO_SESSION, messages: [{ role: 'user' }] })
  assert.equal(read().reason, 'prompt')
})

await check('agent/turn-stopping (root): waiting', async () => {
  await fire(main, 'agent/turn-stopping', { agent: ROOT, turn: 3 })
  const doc = read()
  assert.equal(doc.state, 'waiting')
  assert.equal(doc.reason, 'turn-end')
})

await check('agent/turn-stopping (subagent): ignored — no false green mid-turn', async () => {
  await fire(main, 'agent/turn-stopping', { agent: CHILD, turn: 1 })
  assert.equal(read().reason, 'turn-end')
  assert.equal(read().state, 'waiting')
})

await check('agent/pre-step (subagent prompt): ignored — no false yellow mid-turn', async () => {
  await fire(main, 'agent/pre-step', { agent: CHILD, messages: [{ role: 'user' }] })
  assert.equal(read().state, 'waiting')
  assert.equal(read().sessionId, 'session-root')
})

await check('agent/created (subagent): ignored, session id untouched', async () => {
  await fire(main, 'agent/created', { agent: CHILD })
  assert.equal(read().sessionId, 'session-root')
})

await check('a second prompt flips back to working', async () => {
  await fire(main, 'agent/pre-step', { agent: ROOT, messages: [{ role: 'user' }] })
  assert.equal(read().state, 'working')
})

await check('a permission request blocks the light, and answering returns it to work', async () => {
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const handler = main.handlers.get('approval/request')
  assert.ok(handler, 'no approval/request listener registered')
  const pending = handler({ agent: ROOT, toolName: 'bash' }, () => gate.then(() => 'allow'))
  await sleep(5)
  assert.equal(read().state, 'asking')
  assert.equal(read().reason, 'approval')
  release()
  assert.equal(await pending, 'allow', 'the observer must return the real answer')
  assert.equal(read().state, 'working')
})

await check('a question blocks it too, and two open asks stay blocked until both answer', async () => {
  let releaseA, releaseB
  const gateA = new Promise((resolve) => { releaseA = resolve })
  const gateB = new Promise((resolve) => { releaseB = resolve })
  const ask = main.handlers.get('user-questions/request')
  const handler = main.handlers.get('approval/request')
  const first = handler({ agent: ROOT }, () => gateA.then(() => 'allow'))
  const second = ask({ agent: ROOT }, () => gateB.then(() => 'allow'))
  await sleep(5)
  assert.equal(read().state, 'asking')
  releaseA()
  await first
  await sleep(5)
  assert.equal(read().state, 'asking', 'the second ask is still open')
  releaseB()
  await second
  assert.equal(read().state, 'working')
  assert.equal(read().reason, 'answered')
})

await check('a stopped turn ends the session, though turn-stopping never fires', async () => {
  const child = { session: { id: 'session-child-status', header: { parentSession: 'session-root' } } }
  assert.equal(read().state, 'working')
  await fire(main, 'agent/status', { agent: child, status: 'idle' })
  assert.equal(read().state, 'working', 'a subagent status is not the session moving')

  // The stop path: the loop aborts the turn and never dispatches turn-stopping.
  await fire(main, 'agent/status', { agent: ROOT, status: 'idle' })
  const stopped = read()
  assert.equal(stopped.state, 'waiting', 'a stopped turn must not keep claiming work')
  assert.equal(stopped.reason, 'agent-idle')

  await sleep(5)
  await fire(main, 'agent/status', { agent: ROOT, status: 'idle' })
  assert.equal(read().changedAt, stopped.changedAt, 'idling twice is not a new thing to report')
})

await check('being idle clears an open ask, so a late answer cannot restore work', async () => {
  let release
  const gate = new Promise((resolve) => { release = resolve })
  await fire(main, 'agent/pre-step', { agent: ROOT, messages: [{ role: 'user' }] })
  const pending = main.handlers.get('approval/request')({ agent: ROOT }, () => gate.then(() => 'allow'))
  await sleep(5)
  assert.equal(read().state, 'asking')
  await fire(main, 'agent/status', { agent: ROOT, status: 'idle' })
  assert.equal(read().state, 'waiting')
  release()
  assert.equal(await pending, 'allow', 'the real answer still reaches the asker')
  assert.equal(read().state, 'waiting', 'the answer must not put a finished turn back to working')
})

await check('a turn starting again is what reports it working', async () => {
  await fire(main, 'agent/status', { agent: ROOT, status: 'running' })
  assert.equal(read().state, 'working')
  assert.equal(read().reason, 'agent-running')
})

await check('a real change moves changedAt, and repeating the same state does not', async () => {
  const before = read()
  await sleep(5)
  await fire(main, 'agent/turn-stopping', { agent: ROOT, turn: 9 })
  const after = read()
  assert.equal(after.state, 'waiting')
  assert.ok(after.changedAt > before.changedAt, 'changedAt did not move on a real change')
  assert.equal(after.changedAt, after.updatedAt, 'a publish stamps both timestamps')

  await sleep(5)
  await fire(main, 'agent/turn-stopping', { agent: ROOT, turn: 9 })
  assert.equal(read().changedAt, after.changedAt, 'a repeated identity must keep changedAt')
})

await check('a finish is not hidden by another session still working', async () => {
  const second = { session: { id: 'session-second', header: { cwd: '/tmp/other' } } }
  await fire(main, 'agent/pre-step', { agent: second, messages: [{ role: 'user' }] })
  const doc = read()
  assert.equal(doc.state, 'waiting', 'the finish must stay the headline while the other works')
  assert.equal(doc.sessionId, 'session-root')
  const states = Object.fromEntries(doc.meta.sessions.map((s) => [s.id, s.state]))
  assert.deepEqual(states, { 'session-root': 'waiting', 'session-second': 'working' })
})

await check('a blocked session outranks a finish, and returns to work when answered', async () => {
  const second = { session: { id: 'session-second', header: { cwd: '/tmp/other' } } }
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const pending = main.handlers.get('approval/request')({ agent: second }, () => gate.then(() => 'allow'))
  await sleep(5)
  assert.equal(read().state, 'asking')
  assert.equal(read().meta.sessions.find((s) => s.id === 'session-second').state, 'asking')
  release()
  assert.equal(await pending, 'allow')
  const after = read()
  assert.equal(after.state, 'waiting', 'the finish is the headline again once the ask is answered')
  assert.equal(after.meta.sessions.find((s) => s.id === 'session-second').state, 'working')
})

await check('a subagent ask is charged to its parent session, not to itself', async () => {
  const child = {
    session: { id: 'session-child', header: { parentSession: 'session-root', cwd: '/tmp/project' } }
  }
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const pending = main.handlers.get('approval/request')({ agent: child }, () => gate.then(() => 'allow'))
  await sleep(5)
  const doc = read()
  assert.equal(doc.state, 'asking')
  assert.equal(doc.meta.sessions.find((s) => s.id === 'session-root').state, 'asking')
  assert.equal(doc.meta.sessions.some((s) => s.id === 'session-child'), false)
  release()
  await pending
})

const beat = makeCtx()
const beatPath = join(root, 'beat', 'state.json')
apply(beat.ctx, { statePath: beatPath, heartbeatMs: 250, launch: false, balance: false })
const readBeat = () => JSON.parse(readFileSync(beatPath, 'utf8'))

await check('heartbeat: re-stamps the timestamp without changing the state', async () => {
  const first = readBeat()
  await sleep(600)
  const second = readBeat()
  assert.equal(second.state, 'idle')
  assert.ok(second.updatedAt > first.updatedAt, 'the heartbeat did not advance updatedAt')
  assert.equal(
    second.changedAt,
    first.changedAt,
    'the heartbeat moved changedAt — an acknowledgement would expire one beat after it was made'
  )
})

await check('a mid-turn mount latches the session from turn-stopping alone', async () => {
  const late = makeCtx()
  const latePath = join(root, 'late', 'state.json')
  apply(late.ctx, { statePath: latePath, heartbeatMs: 60000, launch: false, balance: false })
  const readLate = () => JSON.parse(readFileSync(latePath, 'utf8'))
  assert.equal(readLate().sessionId, null, 'nothing is known before the first event')
  await fire(late, 'agent/turn-stopping', { agent: ROOT, turn: 1 })
  const doc = readLate()
  assert.equal(doc.state, 'waiting')
  assert.equal(doc.sessionId, 'session-root', 'the first actionable state must name its session')
  assert.equal(doc.meta.cwd, '/tmp/project')
  assert.ok(Array.isArray(doc.meta.sessions) && doc.meta.sessions.length >= 1)
  for (const dispose of late.disposers) dispose()
})

await check('dispose: clears the timer and publishes a final unknown', () => {
  for (const dispose of main.disposers) dispose()
  const doc = read()
  assert.equal(doc.state, 'idle')
  assert.equal(doc.reason, 'dispose')
  assert.equal(doc.sessionId, null)
})

await check('an unwritable path warns exactly once and never throws', () => {
  const before = warnings.length
  const doomed = makeCtx()
  apply(doomed.ctx, { statePath: '/dev/null/nope/state.json', heartbeatMs: 60000, launch: false, balance: false })
  assert.equal(warnings.length - before, 1, `expected 1 warning, got ${warnings.length - before}`)
  assert.match(warnings.at(-1), /dsh-status: cannot write/)
})

// MARK: the account

/**
 * Key-shaped on purpose: a canary that could not be mistaken for a key would
 * prove nothing about whether keys leak.
 */
const CANARY = 'sk-canary0000000000000000000000000000'

/** The clock as it was before any harness captured it. */
const realSetTimeout = globalThis.setTimeout
const realClearTimeout = globalThis.clearTimeout

/** A wait the harness's stubbed clock cannot swallow: this timer was taken
 *  before the stub existed. */
const sleepReal = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms))

/** The endpoint's answer, as it arrives on this machine. */
const BALANCE_BODY = {
  is_available: true,
  balance_infos: [
    { currency: 'CNY', total_balance: '14.58', granted_balance: '0.00', topped_up_balance: '14.58' },
    { currency: 'USD', total_balance: '0.00', granted_balance: '0.00', topped_up_balance: '0.00' }
  ]
}

/** The part of a `Response` this code uses. */
const answerFor = (status, body) => ({
  status,
  ok: status >= 200 && status < 300,
  json: async () => body
})

/**
 * Mount a publisher with the network, the credential seam and the timers under
 * test control. The suite must never reach DeepSeek, never read the real
 * credential store, and never wait on a real interval.
 */
function mountWithBalance({ response, balance = true, credentials = true, ambient = null } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-status-balance-'))
  const path = join(dir, 'state.json')
  const calls = []
  const refs = []
  const timers = []

  const realFetch = globalThis.fetch
  const realAmbient = process.env.DEEPSEEK_API_KEY
  const scheduled = []

  globalThis.fetch = async (url, options) => {
    calls.push({ url, options })
    return typeof response === 'function' ? response(url, options) : response
  }
  // The account's cadence is captured rather than waited on: a cadence under
  // test control is one that cannot make the suite slow, and one that can be
  // stepped through to prove what it does after a failure.
  globalThis.setTimeout = (fn, ms) => {
    const handle = { fn, ms, unref() {} }
    scheduled.push(handle)
    return handle
  }
  globalThis.clearTimeout = () => {}
  if (ambient === null) delete process.env.DEEPSEEK_API_KEY
  else process.env.DEEPSEEK_API_KEY = ambient

  const seam = {
    resolve: async (ref) => {
      refs.push(ref)
      if (credentials === 'throwing') throw new Error('seam unavailable')
      if (credentials === 'empty') return undefined
      return ref === 'DEEPSEEK_API_KEY' ? { value: CANARY, source: 'store' } : undefined
    }
  }
  const harness = makeCtx(credentials === false ? {} : { credentials: seam })

  apply(harness.ctx, { statePath: path, heartbeatMs: 250, launch: false, balance, balanceMs: 60000 })

  return {
    path,
    calls,
    refs,
    scheduled,
    text: () => readFileSync(path, 'utf8'),
    read: () => JSON.parse(readFileSync(path, 'utf8')),
    /** The account's next scheduled attempt, in milliseconds. */
    nextDelay: () => scheduled.at(-1)?.ms,
    /** Run that attempt now. */
    tick: () => scheduled.at(-1)?.fn(),
    restore: () => {
      globalThis.fetch = realFetch
      globalThis.setTimeout = realSetTimeout
      globalThis.clearTimeout = realClearTimeout
      if (realAmbient === undefined) delete process.env.DEEPSEEK_API_KEY
      else process.env.DEEPSEEK_API_KEY = realAmbient
      rmSync(dir, { recursive: true, force: true })
    }
  }
}

await check('balance: the figures are published, and the key is nowhere', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleepReal(25) // the first lookup is deliberately not awaited
    const doc = mounted.read()

    assert.equal(mounted.refs[0], 'DEEPSEEK_API_KEY', 'the seam is asked for a reference')
    assert.equal(mounted.calls[0].url, 'https://api.deepseek.com/user/balance')
    assert.equal(mounted.calls[0].options.headers.authorization, `Bearer ${CANARY}`)

    assert.equal(doc.meta.account.balances[0].currency, 'CNY')
    assert.equal(doc.meta.account.balances[0].total, '14.58')
    assert.equal(doc.meta.account.balances[1].currency, 'USD')
    assert.equal(doc.meta.account.isAvailable, true)
    assert.equal(doc.meta.account.intervalMs, 60000)
    assert.equal(typeof doc.meta.account.fetchedAt, 'number')

    // The account rides in meta, and the state machine never noticed it.
    assert.equal(doc.state, 'idle')
    assert.equal(doc.reason, 'init')
    assert.equal(doc.meta.sessions.length, 0)

    assert.ok(!mounted.text().includes(CANARY), 'the document must not carry the key')
    assert.ok(!mounted.text().includes('Bearer'), 'not even the scheme')
    assert.ok(!warnings.join('\n').includes(CANARY), 'nor a log line')
  } finally {
    mounted.restore()
  }
})

await check('balance: a refused key is a reason, not a red light', async () => {
  const refusal = { error: { message: 'Authentication Fails, Your api key: ****nary is invalid' } }
  const mounted = mountWithBalance({ response: answerFor(401, refusal) })
  try {
    await sleepReal(25)
    const doc = mounted.read()

    assert.equal(doc.meta.account.reason, 'unauthorized')
    assert.equal(doc.meta.account.balances, undefined)
    // The feed is alive and says so: an account lookup is not a turn.
    assert.equal(doc.state, 'idle')
    assert.equal(typeof doc.updatedAt, 'number')
    assert.ok(!mounted.text().includes('nary'), 'no fragment of the key or the body survives')
    assert.equal(warnings.filter((line) => line.includes('balance')).length, 1)

    // Twice more, and still once: a wrong key is wrong until it is fixed.
    mounted.tick()
    await sleepReal(25)
    mounted.tick()
    await sleepReal(25)
    assert.equal(warnings.filter((line) => line.includes('balance')).length, 1)
  } finally {
    mounted.restore()
  }
})

await check('balance: the snapshot survives a heartbeat', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleepReal(25)
    const first = mounted.read()
    // Only the account's clock is captured; the heartbeat is a real interval at
    // 250ms, so a real wait is the honest way to see one.
    await sleepReal(300)
    const later = mounted.read()

    assert.ok(later.updatedAt > first.updatedAt, 'the heartbeat re-stamped the document')
    assert.equal(later.meta.account.fetchedAt, first.meta.account.fetchedAt, 'the figures did not move')
    assert.equal(later.meta.account.balances[0].total, '14.58')
  } finally {
    mounted.restore()
  }
})

await check('balance: switched off means no request and no block', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY), balance: false })
  try {
    await sleepReal(25)
    assert.equal(mounted.calls.length, 0)
    assert.equal(mounted.read().meta.account, undefined)
    assert.equal(mounted.scheduled.length, 0, 'nothing was scheduled either')
  } finally {
    mounted.restore()
  }
})

await check('balance: the ambient variable is the fallback when the store is empty', async () => {
  // The environment matters only where the seam is present but holds nothing:
  // with no service at all the child never wakes, which is the check above.
  const mounted = mountWithBalance({
    response: answerFor(200, BALANCE_BODY),
    credentials: 'empty',
    ambient: CANARY
  })
  try {
    await sleepReal(25)
    assert.equal(mounted.calls.length, 1, 'the lookup still happened')
    assert.equal(mounted.calls[0].options.headers.authorization, `Bearer ${CANARY}`)
    assert.ok(!mounted.text().includes(CANARY), 'and the key is still not in the document')
  } finally {
    mounted.restore()
  }
})

await check('balance: the account is a child plugin, so the seam arrives by inject', async () => {
  // Not `ctx.get` and not a property on the publisher: in this harness a service
  // reaches a plugin only through its own `inject`. Two earlier versions asked
  // for it the other two ways and reported "no api key configured" against a
  // store that had one — the stub context emulates injection precisely so that
  // mistake cannot pass here again.
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleepReal(25)
    assert.equal(mounted.refs[0], 'DEEPSEEK_API_KEY', 'the seam was asked for the reference')
    assert.equal(mounted.calls.length, 1)
    assert.equal(mounted.calls[0].options.headers.authorization, `Bearer ${CANARY}`)
    assert.equal(mounted.read().meta.account.balances[0].total, '14.58')
  } finally {
    mounted.restore()
  }
})

await check('balance: a seam that refuses to answer falls back to no key', async () => {
  const mounted = mountWithBalance({
    response: answerFor(200, BALANCE_BODY),
    credentials: 'throwing'
  })
  try {
    await sleepReal(25)
    const doc = mounted.read()
    assert.equal(mounted.calls.length, 0, 'nothing was reachable to ask')
    assert.equal(doc.meta.account.reason, 'no-key')
    assert.equal(doc.state, 'idle', 'and the light is untouched')
  } finally {
    mounted.restore()
  }
})

await check('balance: a failure is retried in seconds, and success returns to the period', async () => {
  // The first attempt runs at once. A failure must not wait a whole period: one
  // transient miss used to mean five blank minutes from the outside.
  let answer = answerFor(401, { error: { message: 'nope' } })
  const mounted = mountWithBalance({ response: () => answer })
  try {
    await sleepReal(25)
    assert.equal(mounted.nextDelay(), 15000, 'the first retry is the floor, not the period')

    // Step the cadence: another failure doubles it, and it caps at the period.
    mounted.tick()
    await sleepReal(25)
    assert.equal(mounted.nextDelay(), 30000)

    // A good answer puts it back on the healthy cadence.
    answer = answerFor(200, BALANCE_BODY)
    mounted.tick()
    await sleepReal(25)
    assert.equal(mounted.nextDelay(), 60000)
    assert.equal(mounted.read().meta.account.balances[0].total, '14.58')
  } finally {
    mounted.restore()
  }
})

await check('balance: figures survive a later failure, and the reason explains them', async () => {
  let answer = answerFor(200, BALANCE_BODY)
  const mounted = mountWithBalance({ response: () => answer })
  try {
    await sleepReal(25)
    const good = mounted.read().meta.account
    answer = answerFor(503, {})
    mounted.tick()
    await sleepReal(25)
    const later = mounted.read().meta.account

    assert.equal(later.reason, 'http-503')
    assert.deepEqual(later.balances, good.balances, 'the last true figures are still drawn')
    assert.equal(later.fetchedAt, good.fetchedAt, 'and their age is still their age')
    assert.equal(mounted.read().state, 'idle', 'the light never moved')
  } finally {
    mounted.restore()
  }
})

await check('balance: no credential service costs the account, not the light', async () => {
  // An unsatisfied `inject` leaves the child waiting and never applied. That is
  // the whole reason the account is a child plugin: the publisher itself must
  // mount in any composition.
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY), credentials: false })
  try {
    await sleepReal(25)
    const doc = mounted.read()
    assert.equal(mounted.calls.length, 0, 'nothing to fetch with, so nothing is fetched')
    assert.equal(doc.meta.account, undefined, 'and no block is published from nowhere')
    assert.equal(doc.state, 'idle')
    assert.equal(doc.reason, 'init')
    assert.equal(mounted.scheduled.length, 0, 'the child never scheduled a lookup either')
  } finally {
    mounted.restore()
  }
})

rmSync(root, { recursive: true, force: true })

console.log(`\n${passed} passed, ${failed} failed\n`)
if (failed > 0) process.exitCode = 1
