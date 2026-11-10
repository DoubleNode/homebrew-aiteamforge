import { expect, test } from 'claude-code/testing'

import { BUILTIN_NO_TIER, RUBRIC_SOURCE, classifyDispatch, tierOf } from '../hooks/rubric'

// XACA-1639-001: the rubric as a table. Each row is (input, kind).
const TABLE: [string, Parameters<typeof classifyDispatch>[0], string][] = [
  ['general-purpose, no model', { subagentType: 'general-purpose' }, 'missing-model'],
  ['Explore, no model', { subagentType: 'Explore' }, 'missing-model'],
  ['Plan, no model', { subagentType: 'Plan' }, 'missing-model'],
  ['empty-string model counts as unset', { subagentType: 'Plan', model: '' }, 'missing-model'],
  ['general-purpose on sonnet alias', { subagentType: 'general-purpose', model: 'sonnet' }, 'ok'],
  ['general-purpose on opus full id', { subagentType: 'general-purpose', model: 'claude-opus-5-5' }, 'ok'],
  ['a fork never lacks a model', { subagentType: 'general-purpose', fork: true }, 'ok'],
  ['subagentType fork (the engine type) is not in the list', { subagentType: 'fork' }, 'ok'],
  ['named persona with no model is correct', { subagentType: 'worf' }, 'ok'],
  ['named persona, no model, low effort', { subagentType: 'thok', effort: 'low' }, 'ok'],
  ['opus alias + low', { model: 'opus', effort: 'low' }, 'opus-low'],
  ['opus full id + low', { model: 'claude-opus-5-5', effort: 'low' }, 'opus-low'],
  ['OPUS in capitals + low', { model: 'Claude-OPUS-5-5', effort: 'low' }, 'opus-low'],
  ['opus + high is fine', { model: 'opus', effort: 'high' }, 'ok'],
  ['opus + default effort is fine', { model: 'opus' }, 'ok'],
  ['sonnet + low is the flagship pairing', { model: 'sonnet', effort: 'low' }, 'ok'],
  ['opus + max is the sanctioned rung', { model: 'opus', effort: 'max' }, 'ok'],
  ['fable + max is not flagged here', { model: 'claude-fable-5-1', effort: 'max' }, 'ok'],
  ['sonnet + max is outside the rung', { model: 'claude-sonnet-5-5', effort: 'max' }, 'max-outside-escalation'],
  ['haiku + max is outside the rung', { model: 'haiku', effort: 'max' }, 'max-outside-escalation'],
  ['unrecognised model + max is outside the rung', { model: 'some-other-model', effort: 'max' }, 'max-outside-escalation'],
  ['a numeric effort is not judged', { model: 'opus', effort: 0 }, 'ok'],
  ['max with no model is not judged', { effort: 'max' }, 'ok'],
  ['missing-model wins over an effort smell', { subagentType: 'Plan', effort: 'max' }, 'missing-model'],
]

for (const [name, input, kind] of TABLE) {
  test(`rubric: ${name} -> ${kind}`, () => {
    expect(classifyDispatch(input).kind).toBe(kind)
  })
}

test('every finding cites the rubric source; ok carries no message', () => {
  for (const [, input, kind] of TABLE) {
    const f = classifyDispatch(input)
    if (kind === 'ok') expect(f.message).toBe('')
    else expect(f.message).toContain(RUBRIC_SOURCE)
  }
  expect(RUBRIC_SOURCE).toBe('MODEL_SELECTION.md §2')
})

test('the missing-model message tells the model how to re-dispatch', () => {
  const f = classifyDispatch({ subagentType: 'Explore' })
  expect(f.message).toContain('model: sonnet')
  expect(f.message).toContain('model: opus')
  expect(f.message).toContain('Explore')
})

test('the no-tier list is exactly the three built-ins CLAUDE.md names', () => {
  expect([...BUILTIN_NO_TIER]).toEqual(['general-purpose', 'Explore', 'Plan'])
})

test('tierOf reads aliases and full ids', () => {
  expect(tierOf('opus')).toBe('opus')
  expect(tierOf('claude-sonnet-4-5-20250929')).toBe('sonnet')
  expect(tierOf('claude-fable-5-1')).toBe('fable')
  expect(tierOf('gpt')).toBeNull()
})
