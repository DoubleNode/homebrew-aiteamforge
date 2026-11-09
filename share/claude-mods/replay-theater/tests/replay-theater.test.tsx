import { expect, mock, test } from 'claude-code/testing'

// Consumer layout: a marketplace install does not live under ~/.claude, so the
// shared switchboard file is found from $HOME. Everything else the mod shows it
// records itself (the edits it saw), so it can only be absent, never wrong.
const SWITCHES = '/home/consumer/.claude/mods/switches.json'
const props = { isWorking: false, hasSurvey: false, maxRows: 10, bodyColumns: 100 } as never

for (const hidden of [false, true]) {
  test(`consumer: the switchboard is read from $HOME and ${hidden ? 'hides' : 'shows'} the replay band`, { timeoutMs: 15000 }, async ($, on) => {
    const paths: string[] = []
    const clock = mock.clock(on, { now: 1_000_000 })
    mock.env(on, { HOME: '/home/consumer' })
    on('session.start', async (_$, e) => ({ cwd: e.cwd }) as never)
    on('session.id', async () => ({ value: 'sid' }) as never)
    on('session.cwd', async () => ({ value: '/work/proj' }) as never)
    on('command.register', async () => ({ value: undefined }) as never)
    on('fs.exists', async (_$, e) => {
      paths.push((e as { path: string }).path)
      return { value: hidden && (e as { path: string }).path === SWITCHES } as never
    })
    on('fs.read', async () => ({ value: JSON.stringify({ 'replay-theater:hidden': true }) }) as never)
    on('turn.start', async (_$, e) => ({ turnId: (e as { turnId: string }).turnId }) as never)
    on('turn.complete', async () => ({ text: '' }) as never)
    on('tool.call', async () => ({ result: {} }) as never)
    on('ui.render', { component: 'AbovePrompt' }, async ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>REST</Text>
    })

    await $.session.start({ source: 'startup', cwd: '/work/proj', surface: 'terminal', isInteractive: true } as never)
    await clock.settle()
    await $.turn.start({ text: 'edit', turnId: 't1' } as never)
    await $.tool.call({ tool: 'Edit', file_path: '/work/proj/a.txt', old_string: 'a', new_string: 'b' } as never)
    await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as never)

    const v = await $.ui.mount({ plugin: 'replay-theater', surface: 'terminal', component: 'AbovePrompt', props })
    expect(paths, 'the switchboard path is built from $HOME').toContain(SWITCHES)
    const band = await v.find({ text: /Replay: 1 edit/ })
    if (hidden) expect(band, 'hidden in the shared switchboard: no band').toBeUndefined()
    else expect(band, 'one recorded edit: the band names it').toBeDefined()
    for (const p of paths) expect(p.startsWith('/home/consumer/.claude/')).toBe(true)
  })
}
