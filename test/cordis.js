/**
 * Stage 1 integration test — **real cordis**, real filesystem.
 *
 * `test/run.js` proves the state machine is coherent, but it drives it through
 * a hand-written stub context. This file mounts the plugin into the actual
 * cordis from the shipped app and dispatches through its real dispatchers, so
 * the framework-level claims are verified rather than assumed:
 *
 * - the module is a loadable plugin (`ctx.plugin` accepts it),
 * - `agent/pre-step` delegation really happens: cordis vetoes the rest of the
 *   chain for any listener that fails to call `next()`, so the inner fallback
 *   only runs if our listener delegated,
 * - `ctx.effect` really runs its disposer on fiber disposal,
 * - a bad state path cannot break the mount.
 *
 * It still is not a live harness: no real agent turn drives this. The event
 * payload shape is taken from `agentEvents` in `dsh-agent`, which fuses
 * `{ ...payload, agent }` for every agent-scoped event.
 *
 * Run with `node test/cordis.js`.
 */
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

import * as plugin from '../lib/index.js'

const APP_MODULES =
  process.env.DSH_APP_MODULES ??
  '/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules'

const CORDIS_ENTRY = join(APP_MODULES, '@deepseek-ai/cordis/lib/index.js')

// Skip rather than fail: this test needs the cordis that ships inside DSH
// Desktop, which is not present on a machine that has not installed it.
if (!existsSync(CORDIS_ENTRY)) {
  console.log('dsh-status — cordis integration test SKIPPED')
  console.log(`  no cordis at ${CORDIS_ENTRY}`)
  console.log('  set DSH_APP_MODULES to the app\'s node_modules directory to run it\n')
  process.exit(0)
}

const { Context } = await import(pathToFileURL(CORDIS_ENTRY).href)

const root = mkdtempSync(join(tmpdir(), 'dsh-status-cordis-'))
const statePath = join(root, 'nested', 'state.json')
const read = () => JSON.parse(readFileSync(statePath, 'utf8'))

const ROOT_AGENT = { session: { id: 'session-root', header: { cwd: '/tmp/project' } } }
const CHILD_AGENT = {
  session: { id: 'session-child', header: { parentSession: 'session-root', cwd: '/tmp/project' } }
}

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

console.log('dsh-status — stage 1 under real cordis\n')

const ctx = new Context()
const fork = ctx.plugin(plugin, { statePath, heartbeatMs: 60000 })
await fork

await check('the module mounts as a cordis plugin and publishes init', () => {
  const doc = read()
  assert.equal(doc.state, 'idle')
  assert.equal(doc.reason, 'init')
})

await check('ctx.logger is a real service (the writer has somewhere to warn)', () => {
  assert.equal(typeof ctx.logger?.warn, 'function')
})

await check('agent/created through the real emitter records the session', async () => {
  ctx.emit('agent/created', { agent: ROOT_AGENT, source: 'web' })
  const doc = read()
  assert.equal(doc.state, 'idle')
  assert.equal(doc.sessionId, 'session-root')
  assert.equal(doc.meta.cwd, '/tmp/project')
  assert.deepEqual(doc.meta.sessions.map((s) => s.state), ['idle'])
})

await check('agent/pre-step delegates: the waterfall reaches its inner behaviour', async () => {
  const outcome = await ctx.waterfall(
    'agent/pre-step',
    { agent: ROOT_AGENT, messages: [{ role: 'user' }], turn: 1, step: 1 },
    () => 'reached-inner'
  )
  assert.equal(
    outcome,
    'reached-inner',
    'the listener did not call next() — with real cordis this vetoes the agent step'
  )
  const doc = read()
  assert.equal(doc.state, 'working')
  assert.equal(doc.reason, 'prompt')
})

await check('agent/pre-step with no claimed messages leaves the state alone', async () => {
  await ctx.waterfall('agent/pre-step', { agent: ROOT_AGENT, messages: [], turn: 1, step: 2 }, () => 'inner')
  assert.equal(read().reason, 'prompt')
})

await check('agent/turn-stopping through the real serializer turns the light green', async () => {
  await ctx.serial('agent/turn-stopping', { agent: ROOT_AGENT, turn: 1 })
  const doc = read()
  assert.equal(doc.state, 'waiting')
  assert.equal(doc.reason, 'turn-end')
})

await check('a subagent turn end is ignored under real dispatch — no false green', async () => {
  await ctx.serial('agent/turn-stopping', { agent: CHILD_AGENT, turn: 1 })
  assert.equal(read().state, 'waiting')
  assert.equal(read().sessionId, 'session-root')
})

await check('a subagent prompt is ignored under real dispatch — no false yellow', async () => {
  await ctx.waterfall(
    'agent/pre-step',
    { agent: CHILD_AGENT, messages: [{ role: 'user' }], turn: 1, step: 1 },
    () => 'inner'
  )
  assert.equal(read().state, 'waiting')
})

await check('an approval through the real waterfall still gets the real answer', async () => {
  // Put the session to work first, so the test can prove the ask returns it to
  // the state it was in rather than to a hard-coded one.
  await ctx.waterfall(
    'agent/pre-step',
    { agent: ROOT_AGENT, messages: [{ role: 'user' }], turn: 2, step: 1 },
    () => 'inner'
  )
  const before = read()
  assert.equal(before.state, 'working')

  let release
  const gate = new Promise((resolve) => { release = resolve })
  const pending = ctx.waterfall(
    'approval/request',
    { agent: ROOT_AGENT },
    () => gate.then(() => 'unavailable')
  )
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.equal(read().state, 'asking', 'the observer did not turn the light blue')
  release()
  assert.equal(await pending, 'unavailable', 'the observer swallowed the real answer')
  assert.equal(read().state, 'working', 'the ask must restore the state it interrupted')
})

await check('fiber disposal runs the effect disposer and clears the session', async () => {
  await fork.dispose()
  const doc = read()
  assert.equal(doc.state, 'idle')
  assert.equal(doc.reason, 'dispose')
  assert.equal(doc.sessionId, null)
})

await check('an unwritable state path cannot break the mount', async () => {
  const doomed = new Context()
  const doomedFork = doomed.plugin(plugin, {
    statePath: '/dev/null/nope/state.json',
    heartbeatMs: 60000
  })
  await doomedFork
  await doomedFork.dispose()
})

rmSync(root, { recursive: true, force: true })

console.log(`\n${passed} passed, ${failed} failed\n`)
if (failed > 0) process.exitCode = 1
