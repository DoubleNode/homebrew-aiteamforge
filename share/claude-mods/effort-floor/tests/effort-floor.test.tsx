import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { HOLD, PAUSE } from '../hooks/register'
import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]
type Effort = 'low' | 'medium' | 'high' | 'xhigh' | 'max'

type World = {
  /** The answer the person picks in the ask dialog; null = dismissed. */
  answer: string | null
  asked: string[]
  /** The effort each main/sub request went out with, as the engine saw it. */
  sent: Array<{ turnId: string; index: number; effort: unknown; agentId?: string }>
  ran: string[]
  monitorOut: string
}

// Nothing sits beneath the plugin: these hooks stand for the engine.
function engine(on: On, w: World, fx: SwitchFiles = switchFiles()) {
  mock.clock(on, { now: 1_000_000 })
  mock.env(on, { HOME: fx.home })
  on('command.register', () => ({ value: { command: 'effort-floor' } }))
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('process.run', (_, e) => ({
    value: fx.run(e.argv) ?? { exitCode: 127, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('turn.step', async function* (_, e) {
    w.sent.push({ turnId: e.turnId, index: e.index, effort: e.effort, ...(e.agentId ? { agentId: e.agentId } : {}) })

    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage: null }
  })
  on('tool.call', (_, e) => {
    if (e.tool === 'AskUserQuestion') {
      const q = e.questions[0]
      if (q === undefined) return { deny: 'no question' }
      w.asked.push(q.question)
      if (w.answer === null) return { deny: 'dismissed' }

      return { result: { questions: e.questions, answers: { [q.question]: w.answer } } } as never
    }
    if (e.tool === 'Bash') {
      w.ran.push(e.command)

      return { result: { stdout: e.command.includes('kb-pr-monitor') ? w.monitorOut : 'ok', stderr: '', interrupted: false }, text: e.command.includes('kb-pr-monitor') ? w.monitorOut : 'ok' } as never
    }

    return { result: {} } as never
  })
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>{`modes: ${e.props.modes.join(' & ')}`}</Text>
  })
}

const world = (over: Partial<World> = {}): World => ({ answer: HOLD, asked: [], sent: [], ran: [], monitorOut: '', ...over })

async function drain(stream: AsyncGenerator<unknown, unknown>) {
  for await (const _ of stream) {
    // read to the end
  }
}

const start = ($: Engine, isInteractive = true) =>
  $.session.start({ cwd: '/work', surface: isInteractive ? 'terminal' : null, isInteractive } as never)
const turn = ($: Engine, id: string) => $.turn.start({ text: 'go', turnId: id })
const end = ($: Engine, id: string) => $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: id, reason: 'answer' } as never)
const step = ($: Engine, turnId: string, index: number, effort?: Effort | number, agentId?: string) =>
  drain(
    $.turn.step({
      turnId,
      index,
      model: 'claude-opus-5-5',
      messageCount: 1 + index,
      ...(effort !== undefined ? { effort: effort as never } : {}),
      ...(agentId ? { agentId } : {}),
    }),
  )
const bash = ($: Engine, command: string, agentId?: string) =>
  $.tool.call({ tool: 'Bash', command, ...(agentId ? { agentId } : {}) } as never) as Promise<{ deny?: string; context?: readonly string[] }>

async function modes($: Engine) {
  const ui = await $.ui.mount({ plugin: 'effort-floor', component: 'SessionMode', props: { modes: [] }, surface: 'terminal' })
  const text = (await ui.findAll({ type: 'Text' })).map(t => t.text).find(t => t.startsWith('modes:'))
  await ui.unmount()

  return text
}

const sentIn = (w: World, turnId: string) => w.sent.filter(s => s.turnId === turnId && s.agentId === undefined).map(s => s.effort)

test('Hold: the call is denied with a stop message, and the NEXT turn is raised to High, then released', async ($, on) => {
  const w = world()
  engine(on, w)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  const r = await bash($, 'kb-merge 1315')
  expect(w.asked.length).toBe(1)
  expect(w.asked[0]).toContain('About to merge a PR at Low effort')
  expect(r.deny).toContain('effort-floor held this')
  expect(r.deny).toContain('ask them to reply "go"')
  expect(w.ran, 'the held command never ran').toEqual([])
  await step($, 't1', 1, 'low')
  expect(sentIn(w, 't1'), 'the current turn is not raised (a mid-turn rewrite would not land)').toEqual(['low', 'low'])
  expect(await modes($)).toBe('modes: Held: High from next message (merge)')
  await end($, 't1')

  await turn($, 't2')
  await step($, 't2', 0, 'low')
  await step($, 't2', 1, 'low')
  expect(sentIn(w, 't2'), 'next turn: step 0 raised, its tool step kept High').toEqual(['high', 'high'])
  expect(await modes($)).toBe('modes: Effort raised: High (merge)')
  const again = await bash($, 'kb-merge 1315')
  expect(again.deny, 'no second offer while raised').toBeUndefined()
  expect(w.asked.length).toBe(1)
  await end($, 't2')

  await turn($, 't3')
  await step($, 't3', 0, 'low')
  expect(sentIn(w, 't3'), 'released after the raised turn').toEqual(['low'])
  expect(await modes($)).toBe('modes: ')
})

// PR #1320 BLOCKING 1: the stop message is advice; the held turn itself must refuse every high-stakes call.
const HELD_TURN: Array<[string, string, string]> = [
  ['same command again', 'kb-merge 1315', 'kb-merge 1315'],
  ['equivalent command', 'kb-merge 1315', 'gh pr merge 1315 --squash --admin'],
  ['different class (tap release)', 'kb-merge 1315', 'kb-tap-release patch'],
  ['different class (gitlink)', 'kb-merge 1315', 'git add homebrew-tap'],
  ['a monitor run, which can merge on green', 'kb-merge 1315', 'kb-pr-monitor --pr 1315 --item X'],
  ['after a ROUND_LIMIT hold, a merge', 'kb-pr-monitor --pr 9 --item X', 'kb-merge 9'],
]

for (const [name, first, second] of HELD_TURN) {
  test(`held turn refuses, without asking again: ${name}`, async ($, on) => {
    const w = world({ monitorOut: 'VERDICT: ROUND_LIMIT pr=9 item=X detail=3', answer: first.includes('kb-pr-monitor') ? PAUSE : HOLD })
    engine(on, w)
    await start($)
    await turn($, 't1')
    await step($, 't1', 0, 'low')
    await bash($, first)
    expect(w.asked.length, 'the first call was offered on').toBe(1)
    const ranBefore = w.ran.length
    const r = await bash($, second)
    expect(r.deny ?? '', `${second} is refused in the held turn`).toMatch(/effort-floor (held this|paused after)/)
    expect(w.asked.length, 'no second dialog').toBe(1)
    expect(w.ran.length, `${second} never ran`).toBe(ranBefore)
    expect((await bash($, 'echo ok')).deny, 'an ordinary command still runs').toBeUndefined()
    await end($, 't1')
    await turn($, 't2')
    await step($, 't2', 0, 'low')
    expect((await bash($, second)).deny, 'next turn (raised): runs at High').toBeUndefined()
    expect(sentIn(w, 't2')).toEqual(['high'])
  })
}

test('Run now: the call runs, nothing is raised, and it is not asked again this turn', async ($, on) => {
  const w = world({ answer: 'Run now at Low' })
  engine(on, w)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  const r = await bash($, 'gh pr merge 7 --squash')
  expect(r.deny).toBeUndefined()
  expect(w.ran).toEqual(['gh pr merge 7 --squash'])
  await bash($, 'kb-tap-release patch')
  expect(w.asked.length, 'once per turn').toBe(1)
  expect(w.ran.length).toBe(2)
  await end($, 't1')
  await turn($, 't2')
  await step($, 't2', 0, 'low')
  expect(sentIn(w, 't2')).toEqual(['low'])
  const status = await $.command.run({ command: 'effort-floor', args: '' } as never)
  expect((status as { text: string }).text).toContain('1 offered, 0 held, 0 cancelled, 1 ran as-is')
})

test('interactive: a dismissed dialog (Esc) cancels the call and the rest of its turn, raising nothing', async ($, on) => {
  const w = world({ answer: null })
  engine(on, w)
  await start($, true)
  await turn($, 't1')
  await step($, 't1', 0, 'medium')
  const r = await bash($, 'gh variable set TAP_PUBLISHER_ENABLED --body true')
  expect(w.asked.length).toBe(1)
  expect(r.deny).toContain('the user dismissed the effort question')
  expect((await bash($, 'kb-merge 1')).deny, 'a retry in the cancelled turn is refused too').toContain('dismissed')
  expect(w.asked.length, 'without asking again').toBe(1)
  expect(w.ran).toEqual([])
  const mon = await bash($, 'kb-pr-monitor --pr 1 --item X')
  expect(mon.deny, 'a monitor run is refused, named as itself').toContain('a kb-pr-monitor run, which can merge')
  expect(mon.deny).not.toContain('merge a PR')
  expect((await bash($, 'echo ok')).deny).toBeUndefined()
  await end($, 't1')
  await turn($, 't2')
  await step($, 't2', 0, 'medium')
  expect(sentIn(w, 't2'), 'a cancel raises nothing').toEqual(['medium'])
  expect(w.asked.length).toBe(1)
  const r2 = await bash($, 'kb-merge 1')
  expect(w.asked.length, 'the next turn is offered on again').toBe(2)
  expect(r2.deny).toContain('dismissed')
})

test('headless (no one to ask): a rejected dialog runs the call as it was (fail open)', async ($, on) => {
  const w = world({ answer: null })
  engine(on, w)
  await start($, false)
  await turn($, 't1')
  await step($, 't1', 0, 'medium')
  const r = await bash($, 'gh variable set TAP_PUBLISHER_ENABLED --body true')
  expect(r.deny).toBeUndefined()
  expect(w.ran.length).toBe(1)
})

test('no offer at or above High, on a number budget, on a near-miss, or for a subagent', async ($, on) => {
  const w = world()
  engine(on, w)
  await start($)
  for (const [id, effort] of [['h', 'high'], ['x', 'xhigh'], ['m', 'max']] as const) {
    await turn($, id)
    await step($, id, 0, effort)
    expect((await bash($, 'kb-merge 1')).deny).toBeUndefined()
    await end($, id)
  }
  await turn($, 'n')
  await step($, 'n', 0, 8000)
  expect((await bash($, 'kb-merge 1')).deny).toBeUndefined()
  await end($, 'n')
  await turn($, 'l')
  await step($, 'l', 0, 'low')
  expect((await bash($, 'gh pr view 1')).deny).toBeUndefined()
  expect((await bash($, 'kb-merge 1', 'agent-1')).deny, 'a subagent call is never held').toBeUndefined()
  expect(w.asked).toEqual([])
})

test('raise-only: a hold never lowers a higher level, and subagent steps are untouched', async ($, on) => {
  const w = world()
  engine(on, w)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  expect((await bash($, 'kb-merge 1')).deny).toContain('held')
  await end($, 't1')
  await turn($, 't2')
  await step($, 't2', 0, 'low', 'agent-1')
  expect(w.sent.at(-1)?.effort, 'subagent step keeps its own effort').toBe('low')
  await step($, 't2', 0, 'max')
  expect(sentIn(w, 't2'), 'max stays max').toEqual(['max'])
  await end($, 't2')
  await turn($, 't3')
  await step($, 't3', 0, 'low')
  expect(sentIn(w, 't3'), 'the spent hold raises nothing later').toEqual(['low'])
})

test('off: no offer, nothing held, no footer label', async ($, on) => {
  const fx = switchFiles('/home/me', { 'effort-floor': false })
  const w = world()
  engine(on, w, fx)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  expect((await bash($, 'kb-merge 1')).deny).toBeUndefined()
  expect(w.asked).toEqual([])
  expect(await modes($)).toBe('modes: ')
})

test('ROUND_LIMIT: the monitor runs, and on Pause its result gets the stop message as context', async ($, on) => {
  const w = world({ monitorOut: 'poll\nVERDICT: ROUND_LIMIT pr=9 item=X detail=3 rounds', answer: PAUSE })
  engine(on, w)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  const r = await bash($, 'scripts/kb-pr-monitor --pr 9 --item X')
  expect(w.ran.length, 'the monitor itself always runs').toBe(1)
  expect(r.deny).toBeUndefined()
  expect(w.asked[0]).toContain('ROUND_LIMIT reached at Low effort. Pause and decide the next step at High')
  expect(w.asked[0], 'says what Esc does').toContain('(Esc pauses)')
  expect((r.context ?? []).join('\n')).toContain('do not merge, push, re-run the monitor')
  await end($, 't1')
  await turn($, 't2')
  await step($, 't2', 0, 'low')
  expect(sentIn(w, 't2')).toEqual(['high'])
})

test('a GATES_PASSED monitor result is never offered on', async ($, on) => {
  const w = world({ monitorOut: 'VERDICT: GATES_PASSED pr=9 item=X detail=merged' })
  engine(on, w)
  await start($)
  await turn($, 't1')
  await step($, 't1', 0, 'low')
  const r = await bash($, 'kb-pr-monitor --pr 9 --item X')
  expect(w.asked).toEqual([])
  expect(r.context ?? []).toEqual([])
})
