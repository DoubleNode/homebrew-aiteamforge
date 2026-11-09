import { expect, test } from 'claude-code/testing'

import { MODEL_COLORS, SKILL_COLOR, STATUS } from '../hooks/layout'

// XACA-1605-023/-024: every status carries its own glyph besides its colour,
// and the colours are theme keys, not Tailwind hex.
test('each agent status has a distinct non-colour mark and a theme colour key', () => {
  const marks = Object.values(STATUS).map(s => s.mark)
  expect(new Set(marks).size).toBe(marks.length)
  for (const m of marks) expect(m.trim()).not.toBe('')
  expect(STATUS.running.color).toBe('warning')
  expect(STATUS.done.color).toBe('success')
  expect(STATUS.failed.color).toBe('error')
  expect(SKILL_COLOR).not.toMatch(/^#/)
})

// XACA-1605-033: the model name is foreground-only text, so it takes an engine theme key
// (follows the person's theme), never a raw hex that can fail 4.5:1 on a light theme.
test('every model colour is a theme key, distinct per family, never a raw hex', () => {
  const allowed = new Set<string>(['text', 'inactive', 'subtle', 'suggestion', 'remember', 'success', 'error', 'warning', 'merged', 'claude', 'permission', 'planMode', 'autoAccept'])
  const entries = Object.entries(MODEL_COLORS)
  expect(entries.map(([n]) => n).sort()).toEqual(['fable', 'haiku', 'opus', 'sonnet'])
  for (const [, c] of entries) {
    expect(c).not.toMatch(/^#/)
    expect(allowed.has(c)).toBe(true)
  }
  expect(new Set(entries.map(([, c]) => c)).size).toBe(entries.length)
})

// XACA-1605-037: success/warning/error are the agent STATUS colours (done/running/failed);
// a model (identity) colour must never borrow one of them.
test('model and skill colours never use a status key', () => {
  const status = new Set(Object.values(STATUS).map(s => s.color))
  for (const c of [...Object.values(MODEL_COLORS), SKILL_COLOR]) expect(status.has(c)).toBe(false)
})
