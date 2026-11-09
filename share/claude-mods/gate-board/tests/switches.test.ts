// The shared switch reader/writer (hooks/switches.ts), tested without an engine.
// BYTE-IDENTICAL in every claude-mods/<mod>/tests/ (tests/test-claude-mods-switches-sync.sh).
import { expect, test } from 'claude-code/testing'

import { createSwitch, parseSwitches, readSwitchFile, setSwitch, stateFrom, switchesPath, writeSwitchFile } from '../hooks/switches'
import type { SwitchIo } from '../hooks/switches'
import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

// Lets the poll's promise chain settle (no timers in the test runtime's types).
const flush = async () => {
  for (let i = 0; i < 25; i++) await Promise.resolve()
}

function io(fx: SwitchFiles, extra: Partial<SwitchIo> = {}): SwitchIo {
  return {
    exists: async p => fx.exists(p),
    read: async p => fx.read(p),
    write: async (p, t) => fx.write(p, t),
    run: async argv => fx.run(argv) ?? { exitCode: 127 },
    home: async () => fx.home,
    every: () => undefined,
    root: '/somewhere/else',
    ...extra,
  }
}

test('missing keys mean on and shown; false is off; hidden:true is hidden', () => {
  expect(stateFrom({}, 'm')).toEqual({ off: false, hidden: false })
  expect(stateFrom({ m: false }, 'm')).toEqual({ off: true, hidden: false })
  expect(stateFrom({ 'm:hidden': true }, 'm')).toEqual({ off: false, hidden: true })
  expect(stateFrom({ m: true, 'm:hidden': false }, 'm')).toEqual({ off: false, hidden: false })
  expect(stateFrom({ other: false, 'other:hidden': true }, 'm')).toEqual({ off: false, hidden: false })
})

test('a value that is not a boolean falls back to the default', () => {
  expect(stateFrom({ m: 'no', 'm:hidden': 'yes' }, 'm')).toEqual({ off: false, hidden: false })
  expect(stateFrom({ m: 0, 'm:hidden': 1 }, 'm')).toEqual({ off: false, hidden: false })
  expect(stateFrom({ m: null }, 'm', true)).toEqual({ off: true, hidden: false })
})

test('a defaultOff mod is off until its key says true', () => {
  expect(stateFrom({}, 'm', true)).toEqual({ off: true, hidden: false })
  expect(stateFrom({ m: true }, 'm', true)).toEqual({ off: false, hidden: false })
  expect(stateFrom(null, 'm', true)).toEqual({ off: true, hidden: false })
})

test('malformed text parses to null, never throws; empty text is an empty object', () => {
  for (const bad of ['{', 'nope', '[]', '[1,2]', '"x"', '42', 'null', '{"a":']) expect(parseSwitches(bad)).toBeNull()
  expect(parseSwitches('')).toEqual({})
  expect(parseSwitches('  \n')).toEqual({})
  expect(parseSwitches('{"a":1}')).toEqual({ a: 1 })
  expect(stateFrom(null, 'm')).toEqual({ off: false, hidden: false })
})

test('reading a missing, empty, malformed or throwing file gives defaults and never throws', async () => {
  const fx = switchFiles()
  expect(await readSwitchFile(io(fx), fx.home)).toEqual({})
  fx.put('')
  expect(await readSwitchFile(io(fx), fx.home)).toEqual({})
  fx.put('{ not json')
  expect(await readSwitchFile(io(fx), fx.home)).toBeNull()
  const boom = io(fx, {
    exists: async () => {
      throw new Error('denied')
    },
  })
  expect(await readSwitchFile(boom, fx.home)).toBeNull()
})

test('the writer keeps every other key, and writes through a temp file renamed over the original', async () => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, future: { nested: [1, 2] }, 'other-mod': false })
  expect(await setSwitch(io(fx), fx.home, 'm', { off: true })).toBe(true)
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, future: { nested: [1, 2] }, 'other-mod': false, m: false })
  expect(await setSwitch(io(fx), fx.home, 'm', { hidden: true })).toBe(true)
  expect(await setSwitch(io(fx), fx.home, 'm', { off: false })).toBe(true)
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, future: { nested: [1, 2] }, 'other-mod': false, 'm:hidden': true })
  expect(fx.writes.every(p => p.endsWith('.tmp')), 'the final path is only ever reached by a rename').toBe(true)
  expect(fx.clean(), 'no temp file left behind').toBe(true)
})

test('turning a defaultOff mod on writes true; turning it off writes false', async () => {
  const fx = switchFiles()
  await setSwitch(io(fx), fx.home, 'blast', { off: false }, true)
  expect(fx.json()).toEqual({ blast: true })
  await setSwitch(io(fx), fx.home, 'blast', { off: true }, true)
  expect(fx.json()).toEqual({ blast: false })
})

test('the writer refuses to overwrite a file it cannot read as an object', async () => {
  const fx = switchFiles('/home/me', '{ broken')
  expect(await setSwitch(io(fx), fx.home, 'm', { off: true })).toBe(false)
  expect(fx.files[fx.path], 'the broken file is left for a person to look at').toBe('{ broken')
})

test('without a rename the writer falls back to a plain write and still leaves no temp file', async () => {
  const fx = switchFiles()
  const noMv = io(fx, { run: async argv => (argv[0] === 'mv' ? { exitCode: 1 } : (fx.run(argv) ?? { exitCode: 0 })) })
  await writeSwitchFile(noMv, fx.home, { a: 1 })
  expect(fx.json()).toEqual({ a: 1 })
  expect(fx.clean()).toBe(true)
})

test('HOME wins, and the plugin folder is only the fallback', async () => {
  const fx = switchFiles('/home/me', { m: false })
  const sw = createSwitch('m')
  await sw.start(io(fx))
  expect(sw.off).toBe(true)
  expect(sw.home).toBe('/home/me')
  expect(switchesPath('/x')).toBe('/x/.claude/mods/switches.json')

  const fx2 = switchFiles('/derived', { m: false })
  const sw2 = createSwitch('m')
  await sw2.start(io(fx2, { home: async () => undefined, root: '/derived/.claude/plugins/m' }))
  expect(sw2.off).toBe(true)
})

test('a switch picks up another writer on its poll and reports a flip once', async () => {
  const fx = switchFiles()
  let poll: () => void = () => undefined
  let flips = 0
  const sw = createSwitch('m')
  await sw.start(io(fx, { every: (_ms, fn) => void (poll = fn) }), () => void flips++)
  expect(sw.shown).toBe(true)
  fx.put({ 'm:hidden': true })
  poll()
  await flush()
  expect(sw.hidden).toBe(true)
  expect(sw.shown).toBe(false)
  poll()
  await flush()
  expect(flips, 'an unchanged poll is not a flip').toBe(1)
  fx.put('{ broken')
  poll()
  await flush()
  expect(sw.shown, 'a broken file means the defaults: on and shown').toBe(true)
  expect(sw.problem).toContain('unreadable')
})
