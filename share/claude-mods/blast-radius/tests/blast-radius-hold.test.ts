import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

// XACA-1605-018: the held path (observed through its 2-minute timeout), and what is NOT held: a subagent's
// call, a command damage-control would refuse anyway, and anything while the switch is off.
//
// HARNESS LIMIT: while a tool.call hook is in flight (which is what a hold is), `$.ui.mount(...).find` and
// `.findAll` never resolve, so a test cannot press Proceed or Cancel (checked: the pane renders fine when
// no hold is in flight). The hold is therefore observed from outside: the call stays pending, nothing
// reaches the tool, and it is refused with the timeout reason once the clock passes the limit.
// Proceed and Cancel remain a manual check (README, "Checking it by hand").
type On = Parameters<TestBody>[1]

const HOME = '/home/me'
const RISKY = ['r', 'm', ' -r', 'f /tmp/blast-radius-test-nothing'].join('')
const DC_HOOK = 'uv run /home/me/.claude/hooks/damage-control/bash-tool-damage-control.py'
const ok = (stdout = '', exitCode = 0) => ({ exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

// The hold loop waits on `sleep`; a real macrotask yield keeps it from starving the test body.
const yieldTurn = () => new Promise<void>(r => void (globalThis as unknown as { setTimeout: (f: () => void, ms: number) => void }).setTimeout(r, 2))

type Opts = {
  fx?: SwitchFiles
  settings?: unknown
  /** What the damage-control hook answers (exit code) for a command; default allows. */
  dc?: (command: string) => number
}

/** The engine beneath the mod; `reached` is what got past it to the tool, `ran` every argv the mod ran. */
function engine(on: On, o: Opts = {}) {
  const fx = o.fx ?? switchFiles(HOME, { 'blast-radius': true })
  // Not mock.clock: its advance() waits for in-flight dispatches, and a hold is one. This clock answers
  // clock.now from a variable the test moves, and parks clock.every (the switch poll) for good.
  let now = 1_000_000
  const clock = {
    advance: async (ms: number) => {
      now += ms
    },
    settle: async () => undefined,
  }
  on('clock.now', async () => ({ value: now }) as never)
  on('clock.every', () => new Promise<never>(() => undefined))
  const reached: string[] = []
  const ran: string[][] = []
  const stdins: string[] = []
  const settings = 'settings' in o ? o.settings : { hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: DC_HOOK }] }] } }
  mock.env(on, { HOME })
  on('session.start', async (_$, e) => ({ cwd: e.cwd }) as never)
  on('session.surfaces', async () => ({ value: ['terminal'] }) as never)
  on('session.cwd', async () => ({ value: '/work/proj' }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  on('ui.close', async () => ({ value: undefined }) as never)
  on('ui.toast', async () => ({ value: undefined }) as never)
  on('fs.exists', async (_$, e) => {
    const p = (e as { path: string }).path

    return { value: fx.exists(p) || (p === `${HOME}/.claude/settings.json` && settings !== undefined) } as never
  })
  on('fs.read', async (_$, e) => {
    const p = (e as { path: string }).path

    return { value: p === `${HOME}/.claude/settings.json` ? JSON.stringify(settings) : fx.read(p) } as never
  })
  on('fs.write', async (_$, e) => {
    fx.write((e as { path: string }).path, (e as { text: string }).text)

    return { value: undefined } as never
  })
  on('process.run', async (_$, e) => {
    const { argv, init } = e as { argv: string[]; init?: { stdin?: string } }
    const moved = fx.run(argv)
    if (moved) return { value: moved } as never
    if (argv[0] === 'sleep') {
      await yieldTurn()

      return { value: ok() } as never
    }
    ran.push(argv)
    if (argv[0] === 'sh' && argv[2] === DC_HOOK) {
      stdins.push(String(init?.stdin))

      return { value: ok('', (o.dc ?? (() => 0))(String(JSON.parse(String(init?.stdin)).tool_input.command))) } as never
    }

    return { value: ok(argv[0] === 'bash' ? '0 0 0\n' : '') } as never
  })
  // What the engine would draw beneath the mod (the mod draws the pane itself).
  on('ui.render', { component: 'Pane' }, async ($, e) => $.ui.resolve(e).Text({ children: '' }))
  on('ui.render', { component: 'AbovePrompt' }, async ($, e) => $.ui.resolve(e).Text({ children: '' }))
  on('tool.call', async (_$, e) => {
    reached.push(String((e as { command?: string }).command))

    return { result: {} } as never
  })

  return { fx, clock, reached, ran, stdins }
}

const start = async ($: Engine, clock: { settle: () => Promise<void> }) => {
  await $.session.start({ source: 'startup', cwd: '/work/proj', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}

type Pending = { done: boolean }

/** Starts a Bash call without waiting for it; `pending.done` flips when it resolves. */
function callBash($: Engine, command: string, extra: Record<string, unknown> = {}): { pending: Pending; promise: Promise<unknown> } {
  const pending: Pending = { done: false }
  const promise = Promise.resolve($.tool.call({ tool: 'Bash', command, ...extra } as never)).then(out => {
    pending.done = true

    return out
  })

  return { pending, promise }
}

/** Lets the hold loop run for a while, then reports whether the call is still waiting. */
async function stillWaiting(pending: Pending): Promise<boolean> {
  for (let i = 0; i < 30; i++) await yieldTurn()

  return !pending.done
}

const text = (out: unknown) => JSON.stringify(out ?? {})

test('held: a risky command waits, reaches nothing, and is refused after 2 minutes (not before)', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, reached } = engine(on)
  await start($, clock)
  const { pending, promise } = callBash($, RISKY)
  expect(await stillWaiting(pending), 'held').toBe(true)
  expect(reached, 'nothing reached the tool while held').toEqual([])
  await clock.advance(119_000)
  expect(await stillWaiting(pending), 'still held at 1:59').toBe(true)
  await clock.advance(2_000)
  const out = await promise
  expect(reached, 'the timeout refuses it').toEqual([])
  expect(text(out)).toContain('Blast Radius held this command and did not run it: no answer within 2 minutes')
})

test('a subagent call (agentId set) passes through; the identical call from the main chat is held', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, reached } = engine(on)
  await start($, clock)

  const out = await callBash($, RISKY, { agentId: 'sub-1' }).promise
  expect(reached, 'a subagent call reached the tool with no hold').toEqual([RISKY])
  expect(text(out)).not.toContain('Blast Radius held')

  // Control: the same call from the main loop is held, so the pass-through above is the agentId, not a switch.
  const main = callBash($, RISKY)
  expect(await stillWaiting(main.pending), 'the main-chat call is held').toBe(true)
  expect(reached).toEqual([RISKY])
  await clock.advance(121_000)
  expect(text(await main.promise)).toContain('no answer within 2 minutes')
})

test('a command damage-control refuses anyway passes through; one it allows is held', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, reached, ran, stdins } = engine(on, { dc: command => (command.startsWith('rm ') ? 2 : 0) })
  await start($, clock)

  const refused = await callBash($, RISKY).promise
  expect(reached, 'the rm went on to the next layer, where damage-control denies it').toEqual([RISKY])
  expect(text(refused)).not.toContain('Blast Radius held')
  expect(ran.some(a => a[0] === 'sh' && a[2] === DC_HOOK), 'the configured hook command was asked').toBe(true)
  expect(JSON.parse(stdins[0] ?? '{}')).toMatchObject({ tool_name: 'Bash', tool_input: { command: RISKY } })

  const allowed = callBash($, 'git clean -fdx')
  expect(await stillWaiting(allowed.pending), 'a command damage-control allows is still held').toBe(true)
  expect(reached).toEqual([RISKY])
  await clock.advance(121_000)
  await allowed.promise
})

for (const [name, settings] of [
  ['no settings file', undefined],
  ['a settings file with no hooks', {}],
  ['malformed hooks', { hooks: { PreToolUse: 'nope' } }],
  ['a hook for another tool', { hooks: { PreToolUse: [{ matcher: 'Edit', hooks: [{ type: 'command', command: DC_HOOK }] }] } }],
  ['a hook that is not damage-control', { hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'sh /x/other.sh' }] }] } }],
] as const) {
  test(`damage-control not found (${name}): the command is held as before`, { timeoutMs: 20000 }, async ($, on) => {
    const { clock, reached, ran } = engine(on, { settings, dc: () => 2 })
    await start($, clock)
    const held = callBash($, RISKY)
    expect(await stillWaiting(held.pending), 'held').toBe(true)
    expect(reached).toEqual([])
    expect(ran.some(a => a[0] === 'sh'), 'no hook was run').toBe(false)
    await clock.advance(121_000)
    await held.promise
  })
}

test('a damage-control hook that errors does not unlock the command: it is held', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, reached } = engine(on, { dc: () => 1 })
  await start($, clock)
  const held = callBash($, 'git push --force origin feature/x')
  expect(await stillWaiting(held.pending), 'exit 1 is not a deny: held').toBe(true)
  expect(reached).toEqual([])
  await clock.advance(121_000)
  await held.promise
})

test('off (the default) never holds, and never asks damage-control either', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, reached, ran } = engine(on, { fx: switchFiles(HOME) })
  await start($, clock)
  const out = await callBash($, RISKY).promise
  expect(reached).toEqual([RISKY])
  expect(text(out)).not.toContain('Blast Radius held')
  expect(ran.some(a => a[0] === 'sh')).toBe(false)
})

test('/blast-radius on and off write the shared file and keep its other keys', { timeoutMs: 20000 }, async ($, on) => {
  const { clock, fx } = engine(on, { fx: switchFiles(HOME, { 'goal-meter': false }) })
  await start($, clock)
  const status = async () => String((await $.command.run({ command: 'blast-radius', args: '' } as never)).text)
  expect(await status()).toContain('is off')
  await $.command.run({ command: 'blast-radius', args: 'on' } as never)
  expect(fx.json()).toEqual({ 'goal-meter': false, 'blast-radius': true })
  expect(await status()).toContain('is on')
  await $.command.run({ command: 'blast-radius', args: 'off' } as never)
  expect(fx.json()).toEqual({ 'goal-meter': false, 'blast-radius': false })
  expect(fx.clean()).toBe(true)
})
