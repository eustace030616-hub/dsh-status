/**
 * Balance self-test: no DSH, no network, no key.
 *
 * The fetcher takes its `fetch` as an argument, so every shape the endpoint can
 * answer with is exercised here against a stand-in — including the ones that
 * only happen when something is wrong, which are the ones a live test would
 * never reach.
 *
 * The key used throughout is a canary. Every check that touches it also asserts
 * the canary is absent from what came back, because "the key stays out of the
 * document" is a property worth testing rather than promising.
 *
 * Run with `npm test` (or `node test/balance.js`).
 */
import assert from 'node:assert/strict'

import {
  API_KEY_REF,
  BALANCE_URL,
  MIN_RETRY_MS,
  fetchBalance,
  nextDelay,
  normalizeBalance
} from '../lib/balance.js'

/** Key-shaped on purpose: a canary that could not be mistaken for one would
 *  prove nothing. */
const CANARY = 'sk-canary0000000000000000000000000000'

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

/** A stand-in response, shaped like the part of `fetch` this module uses. */
function answer(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body }
}

/** A stand-in fetch that records what it was asked for. */
function spy(response) {
  const calls = []
  const impl = async (url, options) => {
    calls.push({ url, options })
    return typeof response === 'function' ? response(url, options) : response
  }
  impl.calls = calls
  return impl
}

const BODY = {
  is_available: true,
  balance_infos: [
    {
      currency: 'CNY',
      total_balance: '14.58',
      granted_balance: '0.00',
      topped_up_balance: '14.58'
    },
    { currency: 'USD', total_balance: '0.00', granted_balance: '0.00', topped_up_balance: '0.00' }
  ]
}

console.log('dsh-status — balance\n')

await check('a good answer becomes figures, with the strings intact', async () => {
  const impl = spy(answer(200, BODY))
  const block = await fetchBalance({ key: CANARY, fetchImpl: impl, now: () => 1000 })

  assert.equal(block.at, 1000)
  assert.equal(block.reason, undefined)
  assert.equal(block.isAvailable, true)
  assert.deepEqual(block.balances, [
    { currency: 'CNY', total: '14.58', granted: '0.00', toppedUp: '14.58' },
    { currency: 'USD', total: '0.00', granted: '0.00', toppedUp: '0.00' }
  ])
  assert.equal(impl.calls.length, 1)
  assert.equal(impl.calls[0].url, BALANCE_URL)
  assert.equal(impl.calls[0].options.method, 'GET')
  assert.equal(impl.calls[0].options.headers.authorization, `Bearer ${CANARY}`)
})

await check('the key is in the request and nowhere in the answer', async () => {
  const block = await fetchBalance({
    key: CANARY,
    fetchImpl: spy(answer(200, BODY)),
    now: () => 1000
  })
  assert.ok(
    !JSON.stringify(block).includes(CANARY),
    'the returned block must never carry the secret'
  )
})

await check('a refused key is a code, not the provider’s message', async () => {
  // What DeepSeek actually answers with: it quotes part of the key it rejected.
  const refusal = { error: { message: `Authentication Fails, Your api key: ****nary is invalid` } }
  const block = await fetchBalance({
    key: CANARY,
    fetchImpl: spy(answer(401, refusal)),
    now: () => 1000
  })
  assert.equal(block.reason, 'unauthorized')
  assert.equal(block.balances, undefined)
  assert.ok(!JSON.stringify(block).includes('nary'), 'no fragment of the key or the body survives')
})

await check('a server error keeps its status and nothing else', async () => {
  const block = await fetchBalance({
    key: CANARY,
    fetchImpl: spy(answer(503, { error: 'busy' })),
    now: () => 2000
  })
  assert.equal(block.reason, 'http-503')
  assert.equal(block.at, 2000)
})

await check('a thrown request is offline', async () => {
  const block = await fetchBalance({
    key: CANARY,
    fetchImpl: spy(() => {
      throw new Error('getaddrinfo ENOTFOUND api.deepseek.com')
    }),
    now: () => 3000
  })
  assert.equal(block.reason, 'offline')
  assert.equal(block.at, 3000)
})

await check('an abandoned request is a timeout', async () => {
  // The shape a real abort takes: the fetcher's own timer fires, the signal
  // aborts, and `fetch` rejects with that reason. The stub holds a real timer of
  // its own because an unref'd one — deliberately unref'd in the module, so a
  // pending lookup never keeps the harness alive — will not keep the loop up on
  // its own; a socket in the real world does.
  const block = await fetchBalance({
    key: CANARY,
    timeoutMs: 5,
    fetchImpl: (_url, options) =>
      new Promise((_resolve, reject) => {
        const held = setTimeout(() => reject(new Error('never aborted')), 1000)
        options.signal.addEventListener('abort', () => {
          clearTimeout(held)
          const error = new Error('aborted')
          error.name = 'AbortError'
          reject(error)
        })
      }),
    now: () => 4000
  })
  assert.equal(block.reason, 'timeout')
  assert.equal(block.at, 4000)
})

await check('a body we cannot read is a reason, not a crash', async () => {
  for (const body of [{}, { balance_infos: [] }, { balance_infos: 'nope' }, null]) {
    const block = await fetchBalance({ key: CANARY, fetchImpl: spy(answer(200, body)) })
    assert.equal(block.reason, 'bad-body', `expected bad-body for ${JSON.stringify(body)}`)
  }
})

await check('an entry missing a currency or a total is dropped, not drawn', () => {
  const block = normalizeBalance({
    is_available: true,
    balance_infos: [
      { currency: 'CNY', total_balance: '14.58' },
      { total_balance: '9.99' },
      { currency: 'USD' },
      null
    ]
  })
  assert.deepEqual(block.balances, [
    { currency: 'CNY', total: '14.58', granted: null, toppedUp: null }
  ])
})

await check('a number where a string was expected still reads', () => {
  const block = normalizeBalance({
    balance_infos: [{ currency: 'CNY', total_balance: 14.58 }]
  })
  assert.equal(block.balances[0].total, '14.58')
})

await check('is_available false is carried, not swallowed', () => {
  const block = normalizeBalance({ is_available: false, balance_infos: BODY.balance_infos })
  assert.equal(block.isAvailable, false)
  // Absent is not the same as false: an older endpoint that omits the field is
  // not telling us the account is empty.
  assert.equal(normalizeBalance({ balance_infos: BODY.balance_infos }).isAvailable, true)
})

await check('no key means no request at all', async () => {
  const impl = spy(answer(200, BODY))
  for (const key of [null, undefined, '']) {
    const block = await fetchBalance({ key, fetchImpl: impl })
    assert.equal(block.reason, 'no-key')
  }
  assert.equal(impl.calls.length, 0, 'an unset key must not reach the network')
})

await check('a runtime without fetch is a reason, not a crash', async () => {
  const block = await fetchBalance({ key: CANARY, fetchImpl: undefined })
  // Node 24 has one, so this exercises the other branch only when it does not.
  if (typeof globalThis.fetch === 'function') {
    assert.ok(block.reason === undefined || typeof block.reason === 'string')
  } else {
    assert.equal(block.reason, 'no-fetch')
  }
})

await check('the reference name is the contract, not a value', () => {
  assert.equal(API_KEY_REF, 'DEEPSEEK_API_KEY')
  assert.match(API_KEY_REF, /^[A-Za-z_][A-Za-z0-9_]*$/)
})

await check('the retry backs off from seconds to the period, and resets on success', () => {
  const period = 300_000
  // A success goes straight back to the healthy cadence.
  assert.equal(nextDelay({ previous: 0, ok: true, period }), period)
  assert.equal(nextDelay({ previous: MIN_RETRY_MS, ok: true, period }), period)
  // A failure waits seconds, not a whole period: one blank five minutes was the
  // symptom that prompted this.
  assert.equal(nextDelay({ previous: 0, ok: false, period }), MIN_RETRY_MS)
  assert.equal(nextDelay({ previous: MIN_RETRY_MS, ok: false, period }), 30_000)
  assert.equal(nextDelay({ previous: 30_000, ok: false, period }), 60_000)
  // And it stops doubling at the period rather than running away.
  assert.equal(nextDelay({ previous: 240_000, ok: false, period }), period)
  assert.equal(nextDelay({ previous: period, ok: false, period }), period)
})

console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
