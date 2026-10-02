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

export const DEFAULTS = {
  /** Where the renderer reads state from. Absolute, no `~` expansion. */
  statePath: join(homedir(), 'Library', 'Application Support', 'dsh-status', 'state.json'),
  /** How often the timestamp is refreshed while the state is unchanged. */
  heartbeatMs: 2000
}

/**
 * Fold user config onto the defaults, discarding anything unusable.
 * @param {unknown} config - the plugin's `config` from the patch row.
 * @returns {{statePath: string, heartbeatMs: number}} resolved configuration.
 */
export function resolveConfig(config) {
  const input = config !== null && typeof config === 'object' ? config : {}
  const { statePath, heartbeatMs } = input

  const resolvedPath =
    typeof statePath === 'string' && statePath.startsWith('/') ? statePath : DEFAULTS.statePath

  const resolvedHeartbeat =
    Number.isInteger(heartbeatMs) && heartbeatMs >= MIN_HEARTBEAT_MS
      ? heartbeatMs
      : DEFAULTS.heartbeatMs

  return { statePath: resolvedPath, heartbeatMs: resolvedHeartbeat }
}
