// Dispatch rubric (XACA-1639-001). Own implementation, written from claude/MODEL_SELECTION.md §2
// and claude/CLAUDE.md § Subagent Dispatch.
//
// PURE: no engine, no state, no I/O. One function classifies a (subagentType, model, effort) triple.
//
// BYTE-IDENTICAL in every claude-mods/<mod>/hooks/rubric.ts that carries it. A marketplace install
// copies each mod on its own, so a mod cannot import a sibling's file; the copies are kept equal by
// tests/test-claude-mods-rubric-sync.sh. Edit one, then copy it over the rest.

export const RUBRIC_SOURCE = 'MODEL_SELECTION.md §2'

/**
 * The built-in agent types that carry no `model:` frontmatter tier, so an unset `model` on the Agent call
 * means "inherit the parent" (usually Opus). A named persona has its tier in frontmatter and is not here.
 * One constant: adding a type is a single edit.
 */
export const BUILTIN_NO_TIER: readonly string[] = ['general-purpose', 'Explore', 'Plan']

export type DispatchKind = 'ok' | 'missing-model' | 'opus-low' | 'max-outside-escalation'

export type DispatchInput = {
  subagentType?: string
  /** The Agent call's `model` as given, or the resolved id at a step. Undefined or '' means unset. */
  model?: string
  /** A step's effort. Anything but a level name (a number, undefined) is not judged. */
  effort?: string | number
  /** A fork inherits and the engine ignores its `model`: never a missing-model finding. */
  fork?: boolean
}

export type DispatchFinding = { kind: DispatchKind; message: string }

/** Which tier a model name or id is on: `opus`, `claude-opus-5-5` -> 'opus'; null when it names none we judge. */
export function tierOf(model: string): 'fable' | 'opus' | 'sonnet' | 'haiku' | null {
  const hit = /fable|opus|sonnet|haiku/.exec(model.toLowerCase())

  return hit === null ? null : (hit[0] as 'fable' | 'opus' | 'sonnet' | 'haiku')
}

/**
 * Judges one dispatch against the rubric. The first finding wins, in this order:
 *  - missing-model: a no-tier built-in type (not a fork) with no model set;
 *  - opus-low: `opus` with `low` effort, a smell (declining the deliberation that catches a compounding step);
 *  - max-outside-escalation: `max` effort anywhere but the sanctioned rung (`opus` + `max`, or `fable`).
 * Everything else is ok, including a named persona with no model and `opus` + `max`.
 */
export function classifyDispatch(input: DispatchInput): DispatchFinding {
  const model = input.model ?? ''
  const type = input.subagentType ?? ''

  if (input.fork !== true && model === '' && BUILTIN_NO_TIER.includes(type)) {
    return {
      kind: 'missing-model',
      message:
        `${type} dispatched with no model, so it inherits the parent (usually Opus). ` +
        `Re-dispatch with model: sonnet (routine work) or model: opus (compounding stakes); see ${RUBRIC_SOURCE}.`,
    }
  }

  const tier = tierOf(model)
  const effort = typeof input.effort === 'string' ? input.effort : undefined

  if (tier === 'opus' && effort === 'low') {
    return {
      kind: 'opus-low',
      message:
        `opus with low effort is a configuration smell: Opus is chosen where a wrong step compounds, ` +
        `and low effort declines the deliberation that catches it. Use sonnet + low, or opus at default effort; see ${RUBRIC_SOURCE}.`,
    }
  }
  if (effort === 'max' && tier !== 'opus' && tier !== 'fable' && model !== '') {
    return {
      kind: 'max-outside-escalation',
      message:
        `max effort on ${tier ?? model} is outside the sanctioned escalation rung (opus + max, tried before Fable). ` +
        `Reserve max for that rung; see ${RUBRIC_SOURCE}.`,
    }
  }

  return { kind: 'ok', message: '' }
}
