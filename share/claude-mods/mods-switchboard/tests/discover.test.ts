import { expect, test } from 'claude-code/testing'

import {
  buildRows,
  isHardDisabled,
  listLines,
  mergeEntries,
  nameFromManifest,
  normalize,
  parseMarketplace,
  parsePluginDirs,
  stateLabel,
} from '../hooks/discover'

const MARKET = JSON.stringify({
  plugins: [
    { name: 'a', source: './a', description: 'A mod' },
    { name: 'b', source: './sub/../b' },
    { name: 'blast-radius', source: './blast-radius' },
    { source: './nameless' },
    'junk',
  ],
})

test('the marketplace lists each named plugin with its folder resolved against the base', () => {
  const { entries, problem } = parseMarketplace(MARKET, '/m/claude-mods')
  expect(problem).toBe('')
  expect(entries.map(e => [e.name, e.folder])).toEqual([
    ['a', '/m/claude-mods/a'],
    ['b', '/m/claude-mods/b'],
    ['blast-radius', '/m/claude-mods/blast-radius'],
  ])
  expect(entries[0]?.description).toBe('A mod')
})

test('a marketplace that is not JSON, not an object, or has no plugin list gives no entries and says why', () => {
  for (const bad of ['{ nope', '[]', '"x"', '{}', '{"plugins":"a"}', '']) {
    const r = parseMarketplace(bad, '/m')
    expect(r.entries, bad).toEqual([])
    expect(r.problem, bad).not.toBe('')
  }
})

test('CLAUDE_CODE_PLUGIN_DIRS is split on colons, trimmed, normalised and de-duplicated', () => {
  expect(parsePluginDirs('/a/b: /c/./d::/a/b/')).toEqual(['/a/b', '/c/d'])
  expect(parsePluginDirs('')).toEqual([])
  expect(parsePluginDirs(undefined)).toEqual([])
  expect(normalize('/a/b/../c/./d')).toBe('/a/c/d')
})

test('a manifest gives its name, and anything else gives null', () => {
  expect(nameFromManifest('{"name":"x"}')).toBe('x')
  for (const bad of ['{', '[]', '{"name":3}', '{"name":""}']) expect(nameFromManifest(bad), bad).toBeNull()
})

test('settings disable a plugin only when some enabledPlugins key for it is false and none is true', () => {
  const s = (o: unknown) => JSON.stringify({ enabledPlugins: o })
  expect(isHardDisabled(s({ 'a@aiteamforge-mods': false }), 'a')).toBe(true)
  expect(isHardDisabled(s({ 'a@aiteamforge-mods': false, 'a@inline': true }), 'a')).toBe(false)
  expect(isHardDisabled(s({ 'a@aiteamforge-mods': true }), 'a')).toBe(false)
  expect(isHardDisabled(s({ 'ab@x': false }), 'a'), 'a longer name is not a match').toBe(false)
  expect(isHardDisabled(s({ 'a@x': 'false' }), 'a'), 'only a real boolean counts').toBe(false)
  for (const bad of ['', '{', '[]', '{"enabledPlugins":[]}', '{"x":1}']) expect(isHardDisabled(bad, 'a'), bad).toBe(false)
})

test('marketplace and plugin-dir entries merge by name, marketplace first', () => {
  const market = parseMarketplace(MARKET, '/m').entries
  const merged = mergeEntries(market, [
    { name: 'a', description: 'dir copy', folder: null, pluginDir: '/home/.claude/mods/a' },
    { name: 'zzz', description: 'only a dir', folder: null, pluginDir: '/home/.claude/mods/zzz' },
  ])
  expect(merged.map(e => e.name)).toEqual(['a', 'b', 'blast-radius', 'zzz'])
  expect(merged[0]).toMatchObject({ folder: '/m/a', pluginDir: '/home/.claude/mods/a', description: 'A mod' })
  expect(merged[3]).toMatchObject({ folder: null, pluginDir: '/home/.claude/mods/zzz' })
})

test('rows carry the switch state, the ships-off default, the pane command and the hard state', () => {
  const entries = mergeEntries(parseMarketplace(MARKET, '/m').entries, [])
  const rows = buildRows({
    entries: [...entries, { name: 'goal-meter', description: '', folder: '/m/goal-meter', pluginDir: null }],
    settingsText: JSON.stringify({ enabledPlugins: { 'b@x': false } }),
    switches: { a: false, 'a:hidden': true },
  })
  const by = Object.fromEntries(rows.map(r => [r.name, r]))
  expect(by.a).toMatchObject({ off: true, hidden: true, isHardDisabled: false, isDefaultOff: false })
  expect(by.b).toMatchObject({ off: false, isHardDisabled: true })
  expect(by['blast-radius']).toMatchObject({ off: true, isDefaultOff: true })
  expect(by['goal-meter']?.paneCommand).toBe('goals')
  expect(stateLabel(by.b!)).toContain('not loaded')
  expect(stateLabel(by.a!)).toBe('off')
  expect(stateLabel(by['blast-radius']!)).toBe('off (ships off)')
  expect(listLines(rows)).toHaveLength(4)
})

test('an unreadable switch file (null) shows the defaults', () => {
  const rows = buildRows({ entries: parseMarketplace(MARKET, '/m').entries, settingsText: '', switches: null })
  expect(rows.map(r => [r.name, r.off, r.hidden])).toEqual([['a', false, false], ['b', false, false], ['blast-radius', true, false]])
})
