/**
 * Stage 1 self-test: no DSH, no test framework, no dependencies.
 *
 * A fake cordis context hands us the listeners `apply` registers, so the whole
 * state machine is exercised against a real file on disk in a temp directory.
 * Run with `npm test` (or `node test/run.js`).
 */
import assert from 'node:assert/strict'
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
apply(main.ctx, { statePath, heartbeatMs: 60000 })

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
apply(beat.ctx, { statePath: beatPath, heartbeatMs: 250 })
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
  apply(late.ctx, { statePath: latePath, heartbeatMs: 60000 })
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
  apply(doomed.ctx, { statePath: '/dev/null/nope/state.json', heartbeatMs: 60000 })
  assert.equal(warnings.length - before, 1, `expected 1 warning, got ${warnings.length - before}`)
  assert.match(warnings.at(-1), /dsh-status: cannot write/)
})

rmSync(root, { recursive: true, force: true })

console.log(`\n${passed} passed, ${failed} failed\n`)
if (failed > 0) process.exitCode = 1
