import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

// Academy local patches:
//  - attended sessions only. A headless run (claude -p, kb-run-* gate sessions) draws on no
//    surface, so nobody can press Proceed; the hold would stall before denying. With no surface the
//    hook must pass the call through.
//  - the shared switch file (XACA-1605-016): blast-radius is OFF unless the file says
//    "blast-radius": true. Every other mod is on unless the file says false.

type On = Parameters<TestBody>[1]

const RISKY = ['r', 'm', ' -r', 'f /tmp/blast-radius-test-nothing'].join('')
const ok = (stdout = '') => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

/** The engine beneath the mod: the switch file, surfaces, and a core that records what reaches the tool. */
function engine(on: On, fx: SwitchFiles, surfaces: string[] = ['terminal']) {
  const clock = mock.clock(on, { now: 1_000_000 })
  const reached: string[] = []
  mock.env(on, { HOME: fx.home })
  on('session.start', async (_$, e) => ({ cwd: e.cwd }) as never)
  on('session.surfaces', async () => ({ value: surfaces }) as never)
  on('fs.exists', async (_$, e) => ({ value: fx.exists((e as { path: string }).path) }) as never)
  on('fs.read', async (_$, e) => ({ value: fx.read((e as { path: string }).path) }) as never)
  on('fs.write', async (_$, e) => {
    fx.write((e as { path: string }).path, (e as { text: string }).text)

    return { value: undefined } as never
  })
  on('process.run', async (_$, e) => ({ value: fx.run((e as { argv: string[] }).argv) ?? ok() }) as never)
  on('tool.call', async (_$, e) => {
    reached.push(String((e as { command?: string }).command))

    return { result: {} } as never
  })

  return { clock, reached }
}

const notHeld = (out: unknown) => expect(JSON.stringify(out ?? {}), 'not denied').not.toContain('Blast Radius held')

test('headless session (no surfaces): a risky command passes through, not held', { timeoutMs: 15000 }, async ($, on) => {
  const fx = switchFiles('/home/me', { 'blast-radius': true })
  const { clock, reached } = engine(on, fx, [])
  await $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
  const out = await $.tool.call({ tool: 'Bash', command: RISKY } as never)
  expect(reached, 'the call reached the tool').toEqual([RISKY])
  notHeld(out)
})

test('a harmless command passes through whatever the surfaces', { timeoutMs: 15000 }, async ($, on) => {
  const fx = switchFiles('/home/me', { 'blast-radius': true })
  const { clock, reached } = engine(on, fx)
  await $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
  const out = await $.tool.call({ tool: 'Bash', command: 'ls -la' } as never)
  expect(reached).toEqual(['ls -la'])
  notHeld(out)
})

test('with no switch file the mod is OFF: a risky command passes through even on a drawing surface', { timeoutMs: 15000 }, async ($, on) => {
  const fx = switchFiles()
  const { clock, reached } = engine(on, fx)
  await $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
  const out = await $.tool.call({ tool: 'Bash', command: RISKY } as never)
  expect(reached).toEqual([RISKY])
  notHeld(out)
})

for (const bad of ['{ nope', '[]', '{"blast-radius":"true"}']) {
  test(`a malformed switch file (${bad}) keeps the default: off`, { timeoutMs: 15000 }, async ($, on) => {
    const fx = switchFiles('/home/me', bad)
    const { clock, reached } = engine(on, fx)
    await $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
    await clock.settle()
    const out = await $.tool.call({ tool: 'Bash', command: RISKY } as never)
    expect(reached).toEqual([RISKY])
    notHeld(out)
  })
}

test('an explicit false is off too, and nothing else in the file turns it on', { timeoutMs: 15000 }, async ($, on) => {
  const fx = switchFiles('/home/me', { 'blast-radius': false, 'other-mod': true, 'blast-radius:hidden': false })
  const { clock, reached } = engine(on, fx)
  await $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
  const out = await $.tool.call({ tool: 'Bash', command: RISKY } as never)
  expect(reached).toEqual([RISKY])
  notHeld(out)
})
