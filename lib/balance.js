/**
 * The account balance, reduced to what a renderer can draw: figures, a
 * timestamp, or a reason there are none.
 *
 * Kept in its own module so the network can be handed in. Every test drives this
 * with a stand-in `fetch`, which is why the suite needs no key and no network,
 * and three rules hold throughout:
 *
 * - **The key never leaves this call.** It goes into one request header and
 *   nowhere else: not into the returned block, not into a log line, not into the
 *   published document, and never into a child process.
 * - **A failure is a code, never a body.** The provider's own 401 quotes part of
 *   the key it rejected, so a response body is read only when the answer was a
 *   good one, and is dropped otherwise.
 * - **Nothing here throws.** A balance lookup that fails must not move the
 *   light: red stays reserved for a feed that cannot be trusted.
 *
 * @module dsh-status/balance
 */

/** One GET, no parameters, no body. */
export const BALANCE_URL = 'https://api.deepseek.com/user/balance'

/** The name the key is stored under. The value is resolved by the caller —
 *  this module only ever receives one. */
export const API_KEY_REF = 'DEEPSEEK_API_KEY'

/** How long one request may take before it is abandoned. */
export const DEFAULT_TIMEOUT_MS = 10_000

/**
 * Read one string field, accepting a number as well: the endpoint sends strings
 * today, and a JSON number would otherwise read as a missing figure.
 */
function text(source, key) {
  const value = source[key]
  if (typeof value === 'string') return value
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

/** One currency's figures, or null when the entry cannot be read. */
function figures(entry) {
  if (entry === null || typeof entry !== 'object') return null
  const currency = text(entry, 'currency')
  const total = text(entry, 'total_balance')
  if (currency === null || total === null) return null
  // As the provider wrote them: "14.58" is the figure a user compares against
  // their invoice, and a float would render 14.580000000000002.
  return {
    currency,
    total,
    granted: text(entry, 'granted_balance'),
    toppedUp: text(entry, 'topped_up_balance')
  }
}

/**
 * Reduce a response body to the block the renderer draws, or null when the body
 * is not one we can draw.
 *
 * @param {unknown} body - parsed JSON.
 * @returns {{isAvailable: boolean, balances: object[]}|null}
 */
export function normalizeBalance(body) {
  if (body === null || typeof body !== 'object') return null
  const infos = body.balance_infos
  if (!Array.isArray(infos)) return null
  const balances = infos.map(figures).filter((entry) => entry !== null)
  if (balances.length === 0) return null
  return { isAvailable: body.is_available !== false, balances }
}

/**
 * One balance lookup.
 *
 * @param {object} options
 * @param {string|null} options.key - the resolved secret, or null when unset.
 * @param {Function} [options.fetchImpl] - injected by the tests.
 * @param {Function} [options.now] - clock, injected by the tests.
 * @param {number} [options.timeoutMs] - how long before the request is abandoned.
 * @returns {Promise<{at: number, reason: string}|{at: number, isAvailable: boolean, balances: object[]}>}
 *   Always resolves. `reason` is a code, never a message from the provider.
 */
export async function fetchBalance({
  key,
  fetchImpl,
  now = Date.now,
  timeoutMs = DEFAULT_TIMEOUT_MS
} = {}) {
  const at = now()
  if (typeof key !== 'string' || key.length === 0) return { at, reason: 'no-key' }

  const send = fetchImpl ?? globalThis.fetch
  // A runtime without `fetch` is a reason, not a crash. Node 24 in the harness's
  // main process has one; an older host may not.
  if (typeof send !== 'function') return { at, reason: 'no-fetch' }

  let timer = null
  try {
    const controller = new AbortController()
    timer = setTimeout(() => controller.abort(), timeoutMs)
    timer.unref?.()

    const response = await send(BALANCE_URL, {
      method: 'GET',
      headers: { authorization: `Bearer ${key}`, accept: 'application/json' },
      signal: controller.signal
    })

    if (response.status === 401 || response.status === 403) return { at, reason: 'unauthorized' }
    if (response.ok !== true) return { at, reason: `http-${response.status}` }

    const block = normalizeBalance(await response.json())
    return block === null ? { at, reason: 'bad-body' } : { at, ...block }
  } catch (error) {
    // The message is discarded with the body: a refused connection and an
    // abandoned request are both just "not now", and neither is worth a
    // transcript entry that might quote something.
    return { at, reason: error?.name === 'AbortError' ? 'timeout' : 'offline' }
  } finally {
    if (timer !== null) clearTimeout(timer)
  }
}
