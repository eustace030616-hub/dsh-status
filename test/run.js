/**
 * Stage 1 self-test: no DSH, no test framework, no dependencies.
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

/** A fake cordis context that records listeners and disposers. */
function makeCtx() {
  const handlers = new Map()
  const disposers = []
  const ctx = {
    logger: { warn: (message) => warnings.push(String(message)) },
    on: (event, handler) => handlers.set(event, handler),
    effect: (callback) => disposers.push(callback())
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

console.log('dsh-status — stage 1\n')

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

await check('a permission request turns the light blue, and answering returns it to work', async () => {
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

await check('a question uses the same blue, and two open asks stay blue until both answer', async () => {
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
  const realSetInterval = globalThis.setInterval
  const realClearInterval = globalThis.clearInterval
  const realAmbient = process.env.DEEPSEEK_API_KEY

  globalThis.fetch = async (url, options) => {
    calls.push({ url, options })
    return typeof response === 'function' ? response(url, options) : response
  }
  globalThis.setInterval = (fn, ms) => {
    const handle = { fn, ms, unref() {} }
    timers.push(handle)
    return handle
  }
  globalThis.clearInterval = () => {}
  if (ambient === null) delete process.env.DEEPSEEK_API_KEY
  else process.env.DEEPSEEK_API_KEY = ambient

  const harness = makeCtx()
  const seam = {
    resolve: async (ref) => {
      refs.push(ref)
      return ref === 'DEEPSEEK_API_KEY' ? { value: CANARY, source: 'store' } : undefined
    }
  }
  // `ctx.get` is how cordis reaches a service without the inject requirement,
  // and it is the path the harness actually takes. `'property'` covers the other
  // shape so a context that hands the service over directly keeps working.
  if (credentials === true) harness.ctx.get = (name) => (name === 'credentials' ? seam : undefined)
  else if (credentials === 'property') harness.ctx.credentials = seam
  else if (credentials === 'throwing') {
    harness.ctx.get = () => {
      throw new Error('no such service')
    }
  }

  apply(harness.ctx, { statePath: path, heartbeatMs: 250, launch: false, balance, balanceMs: 60000 })

  return {
    path,
    calls,
    refs,
    timers,
    text: () => readFileSync(path, 'utf8'),
    read: () => JSON.parse(readFileSync(path, 'utf8')),
    /** The account's timer, callable on demand so a cadence can be a test. */
    balanceTimer: () => timers.find((timer) => timer.ms === 60000),
    restore: () => {
      globalThis.fetch = realFetch
      globalThis.setInterval = realSetInterval
      globalThis.clearInterval = realClearInterval
      if (realAmbient === undefined) delete process.env.DEEPSEEK_API_KEY
      else process.env.DEEPSEEK_API_KEY = realAmbient
      rmSync(dir, { recursive: true, force: true })
    }
  }
}

await check('balance: the figures are published, and the key is nowhere', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleep(25) // the first lookup is deliberately not awaited
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
    await sleep(25)
    const doc = mounted.read()

    assert.equal(doc.meta.account.reason, 'unauthorized')
    assert.equal(doc.meta.account.balances, undefined)
    // The feed is alive and says so: an account lookup is not a turn.
    assert.equal(doc.state, 'idle')
    assert.equal(typeof doc.updatedAt, 'number')
    assert.ok(!mounted.text().includes('nary'), 'no fragment of the key or the body survives')
    assert.equal(warnings.filter((line) => line.includes('balance')).length, 1)

    // Twice more, and still once: a wrong key is wrong until it is fixed.
    mounted.balanceTimer().fn()
    mounted.balanceTimer().fn()
    await sleep(25)
    assert.equal(warnings.filter((line) => line.includes('balance')).length, 1)
  } finally {
    mounted.restore()
  }
})

await check('balance: the snapshot survives a heartbeat', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleep(25)
    const first = mounted.read()
    // The heartbeat timer is stubbed like every other one, so fire it by hand
    // rather than waiting: a cadence under test control is a cadence that cannot
    // make the suite slow or flaky. A millisecond first, so the stamp moves.
    await sleep(5)
    mounted.timers.find((timer) => timer.ms === 250).fn()
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
    await sleep(25)
    assert.equal(mounted.calls.length, 0)
    assert.equal(mounted.read().meta.account, undefined)
    assert.equal(mounted.timers.length, 1, 'only the heartbeat timer exists')
  } finally {
    mounted.restore()
  }
})

await check('balance: the ambient variable is the fallback with no seam', async () => {
  const mounted = mountWithBalance({
    response: answerFor(200, BALANCE_BODY),
    credentials: false,
    ambient: CANARY
  })
  try {
    await sleep(25)
    assert.equal(mounted.calls.length, 1, 'the lookup still happened')
    assert.equal(mounted.calls[0].options.headers.authorization, `Bearer ${CANARY}`)
    assert.ok(!mounted.text().includes(CANARY))
  } finally {
    mounted.restore()
  }
})

await check('balance: the service is read without the inject requirement', async () => {
  // cordis answers `undefined` from `ctx.get` when the composition mounts no
  // such service, which is what lets this plugin ask for one without declaring a
  // dependency it would then wait for — and a plugin that waits never mounts.
  // The first version asked `ctx.credentials`, which reaches only *injected*
  // services, and reported "no api key configured" against a store that had one.
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY) })
  try {
    await sleep(25)
    assert.equal(mounted.refs[0], 'DEEPSEEK_API_KEY')
    assert.equal(mounted.calls.length, 1)
    assert.equal(mounted.read().meta.account.balances[0].total, '14.58')
  } finally {
    mounted.restore()
  }
})

await check('balance: a service handed over directly also works', async () => {
  const mounted = mountWithBalance({
    response: answerFor(200, BALANCE_BODY),
    credentials: 'property'
  })
  try {
    await sleep(25)
    assert.equal(mounted.calls.length, 1)
    assert.equal(mounted.read().meta.account.balances[0].total, '14.58')
  } finally {
    mounted.restore()
  }
})

await check('balance: a lookup that throws is a reason, not a crash', async () => {
  const mounted = mountWithBalance({
    response: answerFor(200, BALANCE_BODY),
    credentials: 'throwing'
  })
  try {
    await sleep(25)
    assert.equal(mounted.calls.length, 0, 'nothing was reachable to ask')
    const doc = mounted.read()
    assert.equal(doc.meta.account.reason, 'no-key')
    assert.equal(doc.state, 'idle', 'and the light is untouched')
  } finally {
    mounted.restore()
  }
})

await check('balance: a composition with no credential service is a reason, not a failure', async () => {
  const mounted = mountWithBalance({ response: answerFor(200, BALANCE_BODY), credentials: false })
  try {
    await sleep(25)
    assert.equal(mounted.calls.length, 0, 'an unset key must not reach the network')
    assert.equal(mounted.read().meta.account.reason, 'no-key')
  } finally {
    mounted.restore()
  }
})

rmSync(root, { recursive: true, force: true })

console.log(`\n${passed} passed, ${failed} failed\n`)
if (failed > 0) process.exitCode = 1
