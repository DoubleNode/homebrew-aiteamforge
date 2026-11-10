import { expect, test } from 'claude-code/testing'

import { KEEP_PATHS, elapsed, isNoisePath, mcpServer, tailPath, touchPath } from '../hooks/layout'

// XACA-1639-013: elapsed time reads as a plain duration.
test('elapsed formats seconds, minutes and hours, and never goes negative', () => {
  expect(elapsed(0)).toBe('0s')
  expect(elapsed(999)).toBe('0s')
  expect(elapsed(59_999)).toBe('59s')
  expect(elapsed(60_000)).toBe('1m00s')
  expect(elapsed(65_000)).toBe('1m05s')
  expect(elapsed(3_599_000)).toBe('59m59s')
  expect(elapsed(3_720_000)).toBe('1h02m')
  expect(elapsed(-5_000)).toBe('0s')
})

// XACA-1639-016: what counts as a file this chat used.
test('tool-results spill files and /tmp paths are noise; real paths are not', () => {
  for (const p of ['/tmp/a', '/tmp', '/private/tmp/a', '/home/me/.claude/projects/x/tool-results/y.txt', 'tool-results/z']) {
    expect(isNoisePath(p), p).toBe(true)
  }
  for (const p of ['/repo/tmp/a', '/repo/a.ts', '/tmpfile', '/repo/my-tool-results/a']) {
    expect(isNoisePath(p), p).toBe(false)
  }
})

test('touchPath dedupes, moves a repeat to newest, and keeps the newest KEEP_PATHS', () => {
  expect(touchPath(['a', 'b'], 'a')).toEqual(['b', 'a'])
  expect(touchPath([], 'a')).toEqual(['a'])
  const full = Array.from({ length: KEEP_PATHS }, (_, i) => `/f${i}`)
  const next = touchPath(full, '/new')
  expect(next).toHaveLength(KEEP_PATHS)
  expect(next[0]).toBe('/f1')
  expect(next[KEEP_PATHS - 1]).toBe('/new')
})

test('mcpServer reads the server out of an mcp tool name only', () => {
  expect(mcpServer('mcp__atlassian__getIssue')).toBe('atlassian')
  expect(mcpServer('mcp__plugin_firebase_firebase__firebase_init')).toBe('plugin_firebase_firebase')
  expect(mcpServer('Read')).toBeNull()
  expect(mcpServer('mcp__nothing')).toBeNull()
})

test('tailPath keeps the end of a long path', () => {
  expect(tailPath('/a/b', 10)).toBe('/a/b')
  expect(tailPath('/very/long/path/to/file.ts', 12)).toBe('…/to/file.ts')
})
