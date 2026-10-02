/**
 * The published document and its writer.
 *
 * The document is the entire contract between the plugin and the renderer, so
 * it is versioned and **additive-only**: new information goes into `meta`, new
 * top-level keys are only ever added (never renamed or removed), and `version`
 * is bumped only when a reader written for the old shape would be wrong.
 * Readers must ignore keys they do not know.
 *
 * @module dsh-status/state
 */
import { mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

/** Every state the renderer can be asked to draw. */
export const STATES = Object.freeze(['unknown', 'working', 'waiting'])

/** The only shape version this module writes. */
export const CONTRACT_VERSION = 1

/**
 * Build one complete document. Always complete: a reader never has to merge a
 * partial update, and a missing field always means `null`, not "unchanged".
 *
 * @param {object} fields - state, reason, sessionId, title, meta, heartbeatMs.
 * @param {number} [now] - millisecond clock, injectable for tests.
 * @returns {object} the document to serialize.
 */
export function buildDoc(fields, now = Date.now()) {
  return {
    version: CONTRACT_VERSION,
    state: fields.state,
    sessionId: fields.sessionId ?? null,
    title: fields.title ?? null,
    updatedAt: now,
    heartbeatMs: fields.heartbeatMs,
    reason: fields.reason ?? null,
    meta: fields.meta ?? {}
  }
}

/**
 * Create an atomic, non-throwing writer for one state path.
 *
 * Writes go to a sibling temporary file and are renamed into place, so a
 * reader never observes a half-written document. Every failure is swallowed
 * after the first warning: a status indicator must never be able to break the
 * agent turn that triggered it.
 *
 * @param {string} statePath - absolute destination path.
 * @param {{onError?: (error: unknown) => void}} [options] - first-failure sink.
 * @returns {(doc: object) => boolean} write one document; false when it failed.
 */
export function createWriter(statePath, options = {}) {
  const { onError } = options
  let reported = false

  return function write(doc) {
    try {
      mkdirSync(dirname(statePath), { recursive: true })
      const temporary = `${statePath}.tmp`
      writeFileSync(temporary, `${JSON.stringify(doc)}\n`, 'utf8')
      renameSync(temporary, statePath)
      return true
    } catch (error) {
      if (!reported) {
        reported = true
        onError?.(error)
      }
      return false
    }
  }
}
