import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

// The shared switch file (hooks/switches.ts) decides whether replay-theater records and draws.
type On = Parameters<TestBody>[1]

const props = { isWorking: false, hasSurvey: false, maxRows: 10, bodyColumns: 100 } as never
const ok = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

function engine(on: On, fx: SwitchFiles) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, { HOME: fx.home })
  on('session.start', async (_$, e) => ({ cwd: e.cwd }) as never)
  on('session.id', async () => ({ value: 'sid' }) as never)
  on('session.cwd', async () => ({ value: '/work/proj' }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('fs.exists', async (_$, e) => ({ value: fx.exists((e as { path: string }).path) }) as never)
  on('fs.read', async (_$, e) => ({ value: fx.read((e as { path: string }).path) }) as never)
  on('fs.write', async (_$, e) => {
    fx.write((e as { path: string }).path, (e as { text: string }).text)

    return { value: undefined } as never
  })
  on('process.run', async (_$, e) => ({ value: fx.run((e as { argv: string[] }).argv) ?? ok }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  on('turn.start', async (_$, e) => ({ turnId: (e as { turnId: string }).turnId }) as never)
  on('turn.complete', async () => ({ text: '' }) as never)
  on('tool.call', async () => ({ result: {} }) as never)
  on('ui.render', { component: 'AbovePrompt' }, async ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>REST</Text>
  })

  return clock
}

const start = ($: Engine) => $.session.start({ source: 'startup', cwd: '/work/proj', surface: 'terminal', isInteractive: true } as never)

async function edit($: Engine, id: string) {
  await $.turn.start({ text: 'edit', turnId: id } as never)
  await $.tool.call({ tool: 'Edit', file_path: '/work/proj/a.txt', old_string: 'a', new_string: 'b' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: id, reason: 'answer' } as never)
}

async function band($: Engine) {
  const v = await $.ui.mount({ plugin: 'replay-theater', surface: 'terminal', component: 'AbovePrompt', props })
  const found = (await v.find({ text: /Replay: 1 edit/ })) !== undefined
  const rest = (await v.find({ text: 'REST' })) !== undefined
  await v.unmount()

  return { found, rest }
}

test('off records nothing and draws nothing; on resumes', async ($, on) => {
  const fx = switchFiles('/home/me', { 'replay-theater': false })
  const clock = engine(on, fx)
  await start($)
  await clock.settle()
  await edit($, 't1')
  expect(await band($), 'off: nothing recorded, other bands draw').toEqual({ found: false, rest: true })
  expect(JSON.stringify(await $.command.run({ command: 'replay', args: '' } as never))).toContain('is off')

  fx.put({})
  await clock.advance(3100)
  await edit($, 't2')
  expect((await band($)).found, 'back on: the next edit is recorded').toBe(true)
})

test('hidden still records but draws nothing; the replay command shows it again', async ($, on) => {
  const fx = switchFiles('/home/me', { 'replay-theater:hidden': true, 'other-mod': false })
  const clock = engine(on, fx)
  await start($)
  await clock.settle()
  await edit($, 't1')
  expect(await band($), 'hidden').toEqual({ found: false, rest: true })

  const run = $.command.run({ command: 'replay', args: '' } as never)
  await clock.advance(300)
  await run
  expect(fx.json(), 'the command unhides it and keeps the other keys').toEqual({ 'other-mod': false })
  expect(fx.clean()).toBe(true)
})

test('a missing or malformed switch file shows the band', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx)
  await start($)
  await clock.settle()
  await edit($, 't1')
  expect((await band($)).found, 'missing file: shown').toBe(true)
  for (const bad of ['{ nope', '[]', '{"replay-theater":"false","replay-theater:hidden":"true"}']) {
    fx.put({ 'replay-theater:hidden': true })
    await clock.advance(3100)
    expect((await band($)).found).toBe(false)
    fx.put(bad)
    await clock.advance(3100)
    expect((await band($)).found, `malformed (${bad}): shown`).toBe(true)
  }
})
