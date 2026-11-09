import { expect, test } from 'claude-code/testing'

import { AMBER, GREEN, RED, color } from '../hooks/layout'

// XACA-1605-024: the bands are theme keys; the percent figure is printed beside
// the bar, so a band is never told by colour alone (XACA-1605-023).
test('usage bands use theme colour keys', () => {
  expect([GREEN, AMBER, RED]).toEqual(['success', 'warning', 'error'])
  expect(color(10)).toBe('success')
  expect(color(95)).toBe('error')
  expect(new Set([GREEN, AMBER, RED]).size).toBe(3)
})
