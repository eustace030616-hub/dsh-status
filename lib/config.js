/**
 * Configuration resolution with no dependencies.
 *
 * The package deliberately declares no `dependencies` and no
 * `peerDependencies`: a `link:`-installed plugin does not get its own
 * dependencies installed, and a resolution failure inside a plugin can stop
 * the whole profile from booting. Config is therefore validated by hand and
 * every invalid value falls back to a default rather than throwing.
 *
 * @module dsh-status/config
 */
import { homedir } from 'node:os'
import { join } from 'node:path'

/** Smallest heartbeat that still lets a renderer call the feed live. */
export const MIN_HEARTBEAT_MS = 250

/** Slowest useful balance cadence, and the floor a config value must clear: an
 *  account is charged when a call is made, not second by second, and the
 *  endpoint is somebody else's server. */
export const MIN_BALANCE_MS = 60_000

export const DEFAULTS = {
  /** Where the renderer reads state from. Absolute, no `~` expansion. */
  statePath: join(homedir(), 'Library', 'Application Support', 'dsh-status', 'state.json'),
  /** How often the timestamp is refreshed while the state is unchanged. */
  heartbeatMs: 2000,
  /** Start the renderer that ships in this package, and stop it on dispose. */
  launch: true,
  /** Extra arguments for the renderer, e.g. `['--open', '/Applications/Safari.app',
   *  '--ack-app', 'com.apple.Safari']` when DSH is driven in a browser. */
  lightArgs: [],
  /** Look the account balance up and publish it in `meta.account`. One
   *  authenticated GET per period, and the only request this package makes. */
  balance: true,
  /** How often. Slower than the heartbeat on purpose: the figures move when an
   *  account is charged, so a fresh answer every few minutes is plenty. */
  balanceMs: 300_000
}

/**
 * Fold user config onto the defaults, discarding anything unusable.
 * @param {unknown} config - the plugin's `config` from the patch row.
 * @returns {{statePath: string, heartbeatMs: number, launch: boolean,
 *   lightArgs: string[], balance: boolean, balanceMs: number}} resolved configuration.
 */
export function resolveConfig(config) {
  const input = config !== null && typeof config === 'object' ? config : {}
  const { statePath, heartbeatMs, launch, lightArgs, balance, balanceMs } = input

  const resolvedPath =
    typeof statePath === 'string' && statePath.startsWith('/') ? statePath : DEFAULTS.statePath

  const resolvedHeartbeat =
    Number.isInteger(heartbeatMs) && heartbeatMs >= MIN_HEARTBEAT_MS
      ? heartbeatMs
      : DEFAULTS.heartbeatMs

  const resolvedLaunch = typeof launch === 'boolean' ? launch : DEFAULTS.launch
  const resolvedArgs = Array.isArray(lightArgs)
    ? lightArgs.filter((argument) => typeof argument === 'string')
    : DEFAULTS.lightArgs

  const resolvedBalance = typeof balance === 'boolean' ? balance : DEFAULTS.balance
  const resolvedBalanceMs =
    Number.isInteger(balanceMs) && balanceMs >= MIN_BALANCE_MS ? balanceMs : DEFAULTS.balanceMs

  return {
    statePath: resolvedPath,
    heartbeatMs: resolvedHeartbeat,
    launch: resolvedLaunch,
    lightArgs: resolvedArgs,
    balance: resolvedBalance,
    balanceMs: resolvedBalanceMs
  }
}
