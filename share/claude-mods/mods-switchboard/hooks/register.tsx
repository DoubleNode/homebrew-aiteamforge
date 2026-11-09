import type { EngineInterface, Register } from 'claude-code'

import { SELF, basename, buildRows, descriptionFromManifest, dirname, enableHint, listLines, mergeEntries, nameFromManifest, parseMarketplace, parsePluginDirs, stateLabel } from './discover'
import type { Entry, Row } from './discover'
import { homeOf, readSwitchFile, setSwitch } from './switches'
import type { SwitchIo } from './switches'

const PANE = 'mods'
const POLL_MS = 3000

// BEGIN switch-io (identical in every mod; tests/test-claude-mods-switches-sync.sh keeps it so)
const switchIo = ($: EngineInterface): SwitchIo => ({
  exists: path => $.fs.exists(path),
  read: path => $.fs.read(path),
  write: (path, text) => $.fs.write(path, text),
  run: argv => $.process.run(argv, { timeoutMs: 5000 }),
  home: () => $.env.get('HOME'),
  every: (ms, fn) => $.clock.every(ms, fn),
  root: $.plugin.root,
})
// END switch-io

const HELP = [
  '/mods                    open the Mods pane: every mod, its state, toggles',
  '/mods list              the same as text',
  '/mods on|off <mod>      turn a mod on or off in every chat (remembered)',
  '/mods hide|show <mod>   hide a mod\'s drawing but keep it working, or show it again',
  '/mods open <mod>        open the mod\'s side pane (agent-watch, goal-meter, usage-gauge, replay-theater)',
  'A mod that Claude Code does not load (enabledPlugins false in settings) shows as "not loaded" and has no toggle. To load it: claude plugin enable <mod>@aiteamforge-mods (or /plugin), then restart.',
].join('\n')

// Module state: what the last scan found. Reset on a reload; the next scan rebuilds it.
let rows: Row[] = []
let note = ''
let isOpen = false

async function readText($: EngineInterface, path: string): Promise<string | null> {
  try {
    if (!(await $.fs.exists(path))) return null

    return String(await $.fs.read(path))
  } catch {
    return null
  }
}

/** Reads the marketplace, CLAUDE_CODE_PLUGIN_DIRS, the user settings and the switch file, then rebuilds the rows. */
async function scan($: EngineInterface): Promise<void> {
  const io = switchIo($)
  const home = await homeOf(io)
  const base = dirname($.plugin.root)
  const notes: string[] = []

  let market: Entry[] = []
  const marketText = await readText($, `${base}/.claude-plugin/marketplace.json`)
  if (marketText === null) notes.push('No marketplace.json next to this mod (loaded with --plugin-dir?): listing CLAUDE_CODE_PLUGIN_DIRS only.')
  else {
    const parsed = parseMarketplace(marketText, base)
    market = parsed.entries
    if (parsed.problem !== '') notes.push(parsed.problem)
  }

  const dirs: Entry[] = []
  for (const dir of parsePluginDirs(await $.env.get('CLAUDE_CODE_PLUGIN_DIRS'))) {
    const manifest = await readText($, `${dir}/.claude-plugin/plugin.json`)
    const name = (manifest === null ? null : nameFromManifest(manifest)) ?? basename(dir)
    dirs.push({ name, description: manifest === null ? '' : descriptionFromManifest(manifest), folder: null, pluginDir: dir })
  }

  const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${home}/.claude`
  const settingsText = (await readText($, `${configDir}/settings.json`)) ?? ''
  const switches = await readSwitchFile(io, home)
  if (switches === null) notes.push('switches.json is unreadable: every mod is shown at its default and toggling is refused until it is fixed.')

  rows = buildRows({ entries: mergeEntries(market, dirs), settingsText, switches })
  note = notes.join(' ')
  $.ui.invalidate('ui.render')
}

const find = (name: string) => rows.find(r => r.name === name)

/** One action on one mod. Returns what to tell the person. */
async function act($: EngineInterface, action: string, name: string, fromCommand = false): Promise<string> {
  await scan($)
  const row = find(name)
  if (row === undefined) return `No mod named "${name}". Mods: ${rows.map(r => r.name).join(', ') || 'none found'}.`
  if (row.isHardDisabled) return `${name} is not loaded: it is disabled in settings (enabledPlugins false), so it cannot be switched here. ${enableHint(name)}`

  if (action === 'open') {
    if (row.paneCommand === null) return `${name} has no side pane.`
    if (row.off) return `${name} is off. Turn it on first: /mods on ${name}`
    const command = row.paneCommand
    // The engine refuses a command run from inside a command.run hook (it would wait on the turn the
    // hook holds), so /mods open hands it to a timer; a button press is outside that and runs it now.
    if (fromCommand) {
      $.clock.after(150, () => {
        void $.command.run({ command, args: '' }).catch(() => undefined)
      })

      return `Opening the ${name} pane.`
    }
    try {
      const ran = await $.command.run({ command, args: '' })

      return ran.text ?? `Asked ${name} to open its pane.`
    } catch (err) {
      return `Could not open the ${name} pane: ${String(err).slice(0, 160)}`
    }
  }

  if (row.isSelf && (action === 'off' || action === 'hide')) return 'The Mods pane stays on so there is always a way to bring the others back.'
  const patch = action === 'on' ? { off: false, hidden: false } : action === 'off' ? { off: true } : { hidden: action === 'hide' }
  const io = switchIo($)
  const saved = await setSwitch(io, await homeOf(io), name, patch, row.isDefaultOff)
  await scan($)
  if (!saved) return `Could not change ${name}: switches.json is unreadable. Fix or delete it, then try again.`

  return `${name}: ${stateLabel(find(name) ?? row)}.`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'mods',
      description: 'Mods: list every mod, turn each on or off, hide or show it, open its pane',
      argumentHint: '[list|on|off|hide|show|open <mod>|help]',
    })
    $.clock.every(POLL_MS, () => {
      if (isOpen) void scan($).catch(() => undefined)
    })

    return next(e)
  })

  on('command.run', { command: 'mods' }, async ($, e) => {
    const [word = '', name = ''] = e.args.trim().split(/\s+/)
    const action = word.toLowerCase()
    if (action === 'help') return { text: HELP }

    if (action === '' || action === 'list') {
      await scan($)
      if (action === 'list') return { text: [...listLines(rows), ...(note === '' ? [] : [note])].join('\n') }
      const { isPlaced } = await $.ui.open({ id: PANE, title: 'Mods' })
      isOpen = isPlaced

      return { text: isPlaced ? 'Mods pane opened.' : [...listLines(rows), ...(note === '' ? [] : [note])].join('\n') }
    }
    if (['on', 'off', 'hide', 'show', 'open'].includes(action)) {
      if (name === '') return { text: `Which mod? /mods ${action} <mod>` }

      return { text: await act($, action, name, true) }
    }

    return { text: `Unknown option "${word}".\n${HELP}` }
  })

  // A button's key is "<action>:<mod>"; "toggle" means on or off, "view" means hide or show.
  on('ui.press', { plugin: SELF }, async ($, e) => {
    const [kind = '', name = ''] = e.element.split(':')
    await scan($)
    const row = find(name)
    if (row !== undefined) {
      const action = kind === 'toggle' ? (row.off ? 'on' : 'off') : kind === 'view' ? (row.hidden ? 'show' : 'hide') : kind
      const said = await act($, action, name)
      try {
        $.ui.toast(said)
      } catch {
        // The toast is only a hint; the pane redraws with the new state.
      }
    }

    return { element: e.element }
  })

  on('ui.close', ($, e, next) => {
    if (e.id === PANE) isOpen = false

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const noop = () => undefined

    return (
      <Box flexDirection="column">
        <Text weight="bold">Mods</Text>
        {note !== '' && <Text color="warning">{note}</Text>}
        {rows.length === 0 && <Text dimColor>No mods found.</Text>}
        {rows.map(r => (
          <Box flexDirection="column" key={r.name}>
            <Text> </Text>
            <Text>
              <Text weight="bold">{r.name}</Text>
              <Text color={r.isHardDisabled ? 'error' : r.off ? 'warning' : 'success'}> {stateLabel(r)}</Text>
            </Text>
            {r.isHardDisabled && <Text color="warning" wrap="wrap">{enableHint(r.name)}</Text>}
            {r.description !== '' && <Text dimColor wrap="truncate-end">{r.description}</Text>}
            <Text dimColor wrap="truncate-end">folder: {r.folder ?? '(not in the marketplace)'}</Text>
            {r.pluginDir !== null && <Text dimColor wrap="truncate-end">CLAUDE_CODE_PLUGIN_DIRS: {r.pluginDir}</Text>}
            {!r.isHardDisabled && !r.isSelf && (
              <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
                <Button key={`toggle:${r.name}`} label={`Turn ${r.name} ${r.off ? 'on' : 'off'}`} onPress={noop} />
                <Button key={`view:${r.name}`} label={`${r.hidden ? 'Show' : 'Hide'} ${r.name}`} onPress={noop} />
                {r.paneCommand !== null && !r.off && <Button key={`open:${r.name}`} label={`Open ${r.name} pane`} onPress={noop} />}
                {r.paneCommand !== null && r.off && <Text dimColor wrap="truncate-end">(pane opens once {r.name} is on)</Text>}
              </Box>
            )}
          </Box>
        ))}
      </Box>
    )
  })
}
