import { atom, read, update } from 'claude-code'
import type { EngineInterface, ModelUsage, Register } from 'claude-code'

import type { AgentRec, AgentStatus, Log, Moment } from '../types'
import { createSwitch, homeOf, readSwitchFile, writeSwitchFile } from './switches'
import type { SwitchIo } from './switches'
import { classifyDispatch } from './rubric'
import {
  MAIN,
  SKILL_COLOR,
  STATUS,
  compact,
  cut,
  elapsed,
  isNoisePath,
  label,
  layoutBand,
  mcpServer,
  modelColor,
  shortModel,
  since,
  sumTokens,
  tailPath,
  touchPath,
} from './layout'

const PANE = 'agent-watch'
const KEEP_AGENTS = 200
const KEEP_MOMENTS = 200
// A Skill tool call and the skill.prompt it causes are one run, not two.
const SKILL_PAIR_MS = 30_000
// The tools tool.call leaves alone (see that hook); turn.step counts them.
const UNHOOKED = /^(Agent|Task)$/

const EMPTY: Log = {
  turnSeq: 0,
  sessionStartedAt: 0,
  agents: [],
  turnSkills: [],
  timeline: [],
  lint: { missingModel: 0, opusLow: 0, max: 0 },
  used: { read: [], written: [], mcp: {} },
}

// Change the tag when Log's fields change: it declines what an older
// version stored, which outlives a reload.
const log = atom({ plugin: 'agent-watch', key: 'log' } as const, EMPTY, {
  shape: 'log-2',
})
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('agent-watch')

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

// The dispatch lint's mode lives in the shared switch file beside the on/off keys, as a string:
//   "agent-watch:lint": "deny" | "off"      key absent (or anything else): warn
// The switch helpers only know booleans, so this reads and writes the one key through their file helpers,
// which keep every other key. It is read at each spawn, so another chat's change is picked up at once.
const LINT_KEY = 'agent-watch:lint'
type LintMode = 'warn' | 'deny' | 'off'
const LINT_MODES: readonly string[] = ['warn', 'deny', 'off']
const TICK_MS = 1000

async function readLintMode(io: SwitchIo): Promise<LintMode> {
  try {
    const json = await readSwitchFile(io, await homeOf(io))
    const v = json?.[LINT_KEY]

    return v === 'deny' || v === 'off' ? v : 'warn'
  } catch {
    return 'warn'
  }
}

async function writeLintMode(io: SwitchIo, mode: LintMode): Promise<boolean> {
  try {
    const home = await homeOf(io)
    const json = await readSwitchFile(io, home)
    if (json === null) return false
    if (mode === 'warn') delete json[LINT_KEY]
    else json[LINT_KEY] = mode
    await writeSwitchFile(io, home, json)

    return true
  } catch {
    return false
  }
}

const HELP = [
  '/agent-watch         open the Agents pane',
  '/agent-watch on      turn agent watch on in every chat (remembered)',
  '/agent-watch off     turn it off: no tracking, no band (remembered)',
  '/agent-watch hide    hide the band but keep tracking; show brings it back',
  '/agent-watch clear   forget the agents seen and what this chat used',
  '                     (the lint counters stay)',
  '/agent-watch status  the dispatch lint mode and its session counters',
  '/agent-watch lint    show or set the dispatch lint: warn|deny|off|reset',
  '                     warn is the default; deny refuses a general-purpose,',
  '                     Explore or Plan spawn with no model; reset zeroes',
  '                     the counters',
  '/agent-watch help    this text',
].join('\n')

function countsText(c: Log['lint']): string {
  return `Session: ${c.missingModel} missing-model, ${c.opusLow} opus+low, ${c.max} max-effort.`
}

// The file a Read/Edit/Write/NotebookEdit call names, or null for any other tool or a path we leave out.
function pathOf(e: { tool: string; [k: string]: unknown }): string | null {
  const isTool = e.tool === 'Read' || e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'NotebookEdit'
  if (!isTool) return null
  const raw = e.tool === 'NotebookEdit' ? (e.notebook_path ?? e.file_path) : e.file_path

  return typeof raw === 'string' && raw !== '' && !isNoisePath(raw) ? raw : null
}

function usedBy(u: Log['used'], tool: string, path: string | null, server: string | null): Log['used'] {
  if (path !== null) {
    return tool === 'Read' ? { ...u, read: touchPath(u.read, path) } : { ...u, written: touchPath(u.written, path) }
  }
  if (server !== null) return { ...u, mcp: { ...u.mcp, [server]: (u.mcp[server] ?? 0) + 1 } }

  return u
}

function newAgent(fields: Partial<AgentRec> & { id: string }, l: Log, at: number): AgentRec {
  return {
    parentId: MAIN,
    type: 'agent',
    name: null,
    task: '',
    models: [],
    status: 'running',
    calls: 0,
    tokens: {},
    skills: [],
    startedAt: at,
    endedAt: null,
    effort: null,
    turnSeq: l.turnSeq,
    ...fields,
  }
}

function withAgent(l: Log, id: string, at: number, change: (a: AgentRec) => AgentRec): Log {
  const found = l.agents.some(a => a.id === id)
  const agents = found
    ? l.agents.map(a => (a.id === id ? change(a) : a))
    : [...l.agents, change(newAgent({ id }, l, at))].slice(-KEEP_AGENTS)

  return { ...l, agents }
}

function moment(l: Log, m: Moment): Log {
  return { ...l, timeline: [...l.timeline, m].slice(-KEEP_MOMENTS) }
}

function addModel(a: AgentRec, model: string): AgentRec {
  return a.models.includes(model)
    ? { ...a, models: [...a.models.filter(m => m !== model), model] }
    : { ...a, models: [...a.models, model] }
}

function addUsage(a: AgentRec, model: string, u: ModelUsage): AgentRec {
  const t = a.tokens[model] ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }

  return {
    ...a,
    tokens: {
      ...a.tokens,
      [model]: {
        input: t.input + u.input_tokens,
        output: t.output + u.output_tokens,
        cacheRead: t.cacheRead + u.cache_read_input_tokens,
        cacheWrite: t.cacheWrite + u.cache_creation_input_tokens,
      },
    },
  }
}

function addSkill(l: Log, id: string, skill: string, at: number): Log {
  const next = withAgent(l, id, at, a =>
    a.skills.includes(skill) ? a : { ...a, skills: [...a.skills, skill] },
  )
  const turnSkills = next.turnSkills.includes(skill)
    ? next.turnSkills
    : [...next.turnSkills, skill]

  return { ...next, turnSkills }
}

// An agent the spawn hook never told us about (its spawn nested past us):
// fill in what the agent list knows.
async function ensureAgent($: EngineInterface, id: string, at: number): Promise<void> {
  const l = await read($, log)
  if (l.agents.some(a => a.id === id)) return
  const info = (await $.agent.list().catch(() => [])).find(a => a.id === id)
  await update($, log, cur =>
    cur.agents.some(a => a.id === id)
      ? cur
      : withAgent(cur, id, at, () =>
          newAgent(
            {
              id,
              type: info?.type ?? 'agent',
              name: info?.name ?? null,
              task: info?.description ?? '',
              parentId: info?.parentId ?? MAIN,
            },
            cur,
            at,
          ),
        ),
  )
}

export const register: Register = on => {
  // Module variables: lost on a reload, and nothing drawn depends on them.
  const stepsSeen = new Set<string>()
  // An agent's first request is judged once; a reload forgets, and its next first step is judged again.
  const effortChecked = new Set<string>()
  const skillCalls = new Map<string, number>()
  let spawnsInFlight = 0
  let preloads: string[] = []

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'agent-watch',
      description: 'Agents pane and band: on | off | clear | status | lint | help',
      argumentHint: '[on|off|clear|status|lint [warn|deny|off|reset]|help]',
    })
    await sw.start(switchIo($), () => {
      $.ui.invalidate('ui.render')
    })
    const at = await $.clock.now()
    await update($, log, l => (l.sessionStartedAt === 0 ? { ...l, sessionStartedAt: at } : l))
    // The pane's elapsed time ticks while somebody is running; nothing is drawn or invalidated otherwise.
    $.clock.every(TICK_MS, () => {
      if (sw.off) return
      void read($, log)
        .then(l => {
          if (l.agents.some(a => a.status === 'running')) $.ui.invalidate('ui.render')
        })
        .catch(() => undefined)
    })

    return next(e)
  })

  on('command.run', { command: 'agent-watch' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()

    if (arg === '' && sw.off) return { text: 'Agent watch is off. Turn it on with /agent-watch on, or in /mods.' }
    if (arg === '') {
      const { isPlaced } = await $.ui.open({ id: PANE, title: 'Agents' })

      return { text: isPlaced ? 'Agents pane opened.' : 'Agents pane opens once there is room for it.' }
    }
    if (arg === 'on' || arg === 'off' || arg === 'hide' || arg === 'show') {
      const patch = arg === 'on' ? { off: false, hidden: false } : arg === 'off' ? { off: true } : { hidden: arg === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Agent watch: could not save the switch (switches.json is unreadable).' }

      return { text: `Agent band ${arg}.` }
    }
    if (arg === 'clear') {
      const at = await $.clock.now()
      await update($, log, l => ({
        ...EMPTY,
        lint: l.lint, // the warn-mode evidence outlives a clear; /agent-watch lint reset zeroes it
        turnSeq: l.turnSeq,
        sessionStartedAt: at,
      }))

      return { text: 'Agent watch cleared.' }
    }
    if (arg === 'help') {
      return { text: HELP }
    }
    if (arg === 'status') {
      const l = await read($, log)

      return { text: `Dispatch lint ${await readLintMode(switchIo($))}. ${countsText(l.lint)}` }
    }
    if (arg === 'lint' || arg.startsWith('lint ')) {
      const want = arg.slice(4).trim()
      if (want === '') return { text: `Dispatch lint is ${await readLintMode(switchIo($))}. Set it with /agent-watch lint warn|deny|off (reset zeroes the counters).` }
      if (want === 'reset') {
        await update($, log, l => ({ ...l, lint: { missingModel: 0, opusLow: 0, max: 0 } }))

        return { text: 'Dispatch lint counters reset.' }
      }
      if (!LINT_MODES.includes(want)) return { text: `Unknown lint mode "${want}". Use warn, deny or off.` }
      if (!(await writeLintMode(switchIo($), want as LintMode))) {
        return { text: 'Agent watch: could not save the lint mode (switches.json is unreadable).' }
      }

      return {
        text:
          want === 'deny'
            ? 'Dispatch lint deny: a general-purpose, Explore or Plan spawn with no model is refused. Effort findings stay warnings.'
            : `Dispatch lint ${want}.`,
      }
    }

    return { text: `Unknown option "${arg}".\n${HELP}` }
  })

  on('turn.start', async ($, e, next) => {
    if (sw.off) return next(e)
    const at = await $.clock.now()

    if (e.agentId === undefined) {
      // A turn the engine started (a task notification, a continuation) is
      // not a new ask: it keeps the person's task and the band's agents.
      const tag = /^\s*<([\w-]+)>/.exec(e.text)?.[1]
      const isMachine = e.text.trim() === '' || tag !== undefined
      await update($, log, l => {
        const turnSeq = isMachine && l.turnSeq > 0 ? l.turnSeq : l.turnSeq + 1
        const base = turnSeq === l.turnSeq ? l : { ...l, turnSeq, turnSkills: [] }
        const started = withAgent(base, MAIN, at, a => ({
          ...a,
          type: 'main',
          parentId: null,
          task: isMachine ? a.task : e.text,
          status: 'running',
          turnSeq,
          endedAt: null,
        }))
        const text = isMachine ? `main (${tag ?? 'continued'})` : `main "${cut(e.text, 40)}"`

        return moment(started, { at, agentId: MAIN, text, status: 'running' })
      })
    } else {
      await ensureAgent($, e.agentId, at)
      await update($, log, l =>
        withAgent(l, e.agentId ?? MAIN, at, a => ({ ...a, status: 'running', endedAt: null })),
      )
    }

    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    // The effort half of the dispatch lint runs on its own setting (agent-watch:lint), not the band's switch:
    // an off or hidden band does not stop it. Effort cannot be seen at agent.spawn, so each subagent's FIRST
    // request is judged here, once. Warnings only.
    const first = e.agentId !== undefined && e.index === 0 && !effortChecked.has(e.agentId)
    if (first && e.agentId !== undefined) {
      effortChecked.add(e.agentId)
      const mode = await readLintMode(switchIo($))
      const found = mode === 'off' ? undefined : classifyDispatch({ model: e.model, effort: e.effort })
      if (found !== undefined && (found.kind === 'opus-low' || found.kind === 'max-outside-escalation')) {
        const key = found.kind === 'opus-low' ? 'opusLow' : 'max'
        await update($, log, l => ({ ...l, lint: { ...l.lint, [key]: l.lint[key] + 1 } }))
        $.ui.log(`agent-watch: ${found.message}`)
      }
    }
    if (sw.off) return yield* next(e)
    const id = e.agentId ?? MAIN
    const at = await $.clock.now()
    stepsSeen.add(e.turnId)
    if (e.agentId !== undefined) await ensureAgent($, e.agentId, at)
    await update($, log, l => withAgent(l, id, at, a => addModel(a, e.model)))

    if (first && e.agentId !== undefined) {
      const agentId = e.agentId
      const effort = e.effort === undefined ? null : String(e.effort)
      await update($, log, l => withAgent(l, agentId, at, a => ({ ...a, effort })))
    }

    const result = yield* next(e)
    const usage = result.usage
    // Agent calls are counted here, since the tool.call hook stays off them.
    const spawns = result.toolUses.filter(u => UNHOOKED.test(u.name)).length
    if (usage !== null || spawns > 0) {
      await update($, log, l =>
        withAgent(l, id, at, a => {
          const counted = { ...a, calls: a.calls + spawns }

          return usage === null ? counted : addUsage(counted, usage.model || e.model, usage)
        }),
      )
    }

    return result
  })

  // Every tool but Agent: a hook wrapped around the Agent call would sit in
  // the frame the subagent spawns from, and the engine skips such hooks for
  // that subagent's own events.
  on('tool.call', { tool: /^(?!(Agent|Task)$)/ }, async ($, e, next) => {
    if (sw.off) return next(e)
    const id = e.agentId ?? MAIN
    const at = await $.clock.now()
    const skill =
      e.tool === 'Skill' && typeof (e as { skill?: unknown }).skill === 'string'
        ? (e as { skill: string }).skill
        : null

    const path = pathOf(e)
    const server = mcpServer(e.tool)
    await update($, log, l => {
      const counted = withAgent(l, id, at, a => ({ ...a, calls: a.calls + 1 }))
      const used = usedBy(counted.used, e.tool, path, server)
      const withUsed = used === counted.used ? counted : { ...counted, used }

      return skill === null ? withUsed : addSkill(withUsed, id, skill, at)
    })
    if (skill !== null) skillCalls.set(skill, at)

    return next(e)
  }).catch(($, e, next) => next(e)) // an observer never blocks a tool

  on('skill.prompt', async ($, e, next) => {
    if (sw.off) return next(e)
    const at = await $.clock.now()
    const pairedAt = skillCalls.get(e.skill)

    if (pairedAt !== undefined && at - pairedAt <= SKILL_PAIR_MS) {
      // Already counted at its Skill tool call.
      skillCalls.delete(e.skill)
    } else if (spawnsInFlight > 0) {
      // Preloaded into an agent being spawned; it gets it once its id is known.
      preloads = [...preloads, e.skill]
    } else {
      // Typed as /name in the main chat.
      await update($, log, l => addSkill(l, MAIN, e.skill, at))
    }

    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    // The model half of the dispatch lint, on its own setting (agent-watch:lint): an off or hidden band does not
    // disable it, a user-selected deny still refuses. A fork is exempt (classifyDispatch); a named persona is not in
    // the rubric's no-tier list. Also exempt, since inheriting the parent is not what happens there: a workflow
    // script's agent() and a resumed agent (both named on the spawn event), and any spawn while the session forces
    // one subagent model (CLAUDE_CODE_SUBAGENT_MODEL). The counter moves in warn and deny alike; only deny refuses.
    const mode = await readLintMode(switchIo($))
    let found = mode === 'off' ? undefined : classifyDispatch({ subagentType: e.subagentType, model: e.model, fork: e.fork })
    if (found?.kind === 'missing-model') {
      const forced = (await $.env.get('CLAUDE_CODE_SUBAGENT_MODEL').catch(() => undefined)) ?? ''
      if (e.workflow !== undefined || e.resume !== undefined || forced.trim() !== '') found = undefined
    }
    const lintMessage = found?.kind === 'missing-model' ? `agent-watch: ${found.message}` : undefined
    if (lintMessage !== undefined) {
      await update($, log, l => ({ ...l, lint: { ...l.lint, missingModel: l.lint.missingModel + 1 } }))
      if (mode === 'deny') return { deny: lintMessage }
    }
    const announce = () => {
      if (lintMessage === undefined) return
      // The notice sits under the open Agent call and goes when the call resolves, or is dropped when none is
      // open; the dim transcript line is always written too, so a finding is never silently lost.
      try {
        $.ui.notice(e.tool_use_id, lintMessage)
      } catch {
        // the log line below still carries it
      }
      $.ui.log(lintMessage)
    }
    if (sw.off) {
      const passed = await next(e)
      if (passed.deny === undefined) announce()

      return passed
    }

    spawnsInFlight += 1
    let ran
    try {
      ran = await next(e)
    } finally {
      spawnsInFlight -= 1
    }
    const agentId = ran.agentId
    if (ran.deny !== undefined || agentId === undefined) return ran
    announce()

    const at = await $.clock.now()
    const skills = preloads
    preloads = []
    await update($, log, l => {
      let cur = withAgent(l, agentId, at, a => ({
        ...a,
        type: e.subagentType,
        name: e.name ?? null,
        task: e.description !== '' ? e.description : e.prompt,
        parentId: e.parentAgentId ?? MAIN,
        models: a.models.includes(ran.model) ? a.models : [ran.model, ...a.models],
      }))
      for (const skill of skills) cur = addSkill(cur, agentId, skill, at)
      const kind = e.name ?? e.subagentType

      return moment(cur, { at, agentId, text: `${kind} "${cut(e.description || e.prompt, 40)}"`, status: 'running' })
    })

    return ran
  }).catch(($, e, next) => next(e)) // nor a spawn

  on('turn.complete', async ($, e, next) => {
    if (sw.off) return next(e)
    const id = e.agentId ?? MAIN
    const at = await $.clock.now()
    const status: AgentStatus = e.reason === 'answer' ? 'done' : 'failed'
    const hadSteps = stepsSeen.delete(e.turnId)

    // Steps skipped us (a nested spawn): count calls from its transcript.
    let calls: number | null = null
    if (!hadSteps && e.agentId !== undefined) {
      await ensureAgent($, e.agentId, at)
      const rows = await $.session.messages({ agentId: e.agentId }).catch(() => null)
      if (Array.isArray(rows)) calls = rows.reduce((n, r) => n + r.toolUses.length, 0)
    }

    await update($, log, l => {
      const ended = withAgent(l, id, at, a => {
        let cur: AgentRec = { ...a, status, endedAt: at }
        if (!hadSteps && e.usage !== undefined) {
          cur = addUsage(addModel(cur, e.usage.model), e.usage.model, e.usage)
        }
        if (calls !== null && cur.calls < calls) cur = { ...cur, calls }

        return cur
      })
      const agent = ended.agents.find(a => a.id === id)
      const name = agent === undefined ? id : label(agent)

      return moment(ended, { at, agentId: id, text: `${name} ${status}`, status })
    })

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below

    const l = await read($, log)
    if (l.turnSeq === 0) return below

    const main = l.agents.find(a => a.id === MAIN)
    const helpers = l.agents.filter(a => a.id !== MAIN && a.turnSeq === l.turnSeq)
    const segs = layoutBand(main, helpers, l.turnSkills, e.props.bodyColumns)
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end">
          {segs.map(s => (
            <Text
              color={s.color}
              backgroundColor={s.bg}
              weight={s.isBold ? 'bold' : undefined}
              dimColor={s.isDim}
            >
              {s.text}
            </Text>
          ))}
        </Text>
        {below}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const l = await read($, log)

    if (l.agents.length === 0) {
      return (
        <Box flexDirection="column">
          <Text dimColor>No agents yet. They show up here as they work.</Text>
        </Box>
      )
    }

    // Helpers nested under their parent, in the order they started.
    // A parent we no longer hold (cleared, or past KEEP_AGENTS) reads as main.
    const ids = new Set(l.agents.map(a => a.id))
    const parentOf = (a: AgentRec) =>
      a.parentId !== null && ids.has(a.parentId) ? a.parentId : MAIN
    const ordered: { agent: AgentRec; depth: number }[] = []
    const seen = new Set<string>()
    const walk = (parent: string, depth: number) => {
      for (const agent of l.agents) {
        if (agent.id !== MAIN && !seen.has(agent.id) && parentOf(agent) === parent) {
          seen.add(agent.id)
          ordered.push({ agent, depth })
          walk(agent.id, depth + 1)
        }
      }
    }
    const main = l.agents.find(a => a.id === MAIN)
    if (main !== undefined) ordered.push({ agent: main, depth: 0 })
    walk(MAIN, main === undefined ? 0 : 1)

    // Totals per model, across every agent.
    const perModel = new Map<string, ReturnType<typeof sumTokens>>()
    for (const agent of l.agents) {
      for (const [model, t] of Object.entries(agent.tokens)) {
        const name = shortModel(model, true)
        const cur = perModel.get(name) ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        perModel.set(name, {
          input: cur.input + t.input,
          output: cur.output + t.output,
          cacheRead: cur.cacheRead + t.cacheRead,
          cacheWrite: cur.cacheWrite + t.cacheWrite,
        })
      }
    }

    const room = Math.max(4, Math.min(12, (e.viewport?.rows ?? 24) - 8))
    const now = await $.clock.now()
    const mode = await readLintMode(switchIo($))
    const readFiles = l.used.read
    const wroteFiles = l.used.written
    const servers = Object.entries(l.used.mcp)
    const hasUsed = readFiles.length > 0 || wroteFiles.length > 0 || servers.length > 0
    const SHOWN = 6
    const fileRows = (title: string, list: string[]) =>
      list.length === 0 ? null : (
        <Box flexDirection="column">
          <Text>
            <Text dimColor>{title}</Text> <Text dimColor>({list.length})</Text>
          </Text>
          {list.slice(-SHOWN).reverse().map(p => (
            <Text wrap="truncate-end">  {tailPath(p)}</Text>
          ))}
          {list.length > SHOWN && <Text dimColor>  +{list.length - SHOWN} more</Text>}
        </Box>
      )

    return (
      <Box flexDirection="column">
        {ordered.map(({ agent, depth }) => {
          const pad = '  '.repeat(depth)
          const status = STATUS[agent.status]
          const t = sumTokens(agent.tokens)
          const models = agent.models.map(m => shortModel(m, true)).join(', ') || '?'
          const task = agent.task === '' ? '' : ` — ${cut(agent.task, 60)}`

          return (
            <Box flexDirection="column">
              <Text wrap="truncate-end">
                {pad}
                <Text color={status.color}>{status.mark}</Text> <Text weight="bold">{label(agent)}</Text>
                {task}
              </Text>
              <Text dimColor wrap="truncate-end">
                {pad}  {models} · {agent.calls} calls · {compact(t.input + t.cacheRead + t.cacheWrite)} in / {compact(t.output)} out
                {agent.effort === null ? '' : ` · effort ${agent.effort}`} · {elapsed((agent.endedAt ?? now) - agent.startedAt)}
              </Text>
              {agent.skills.length > 0 && (
                <Text wrap="truncate-end">
                  {pad}  <Text dimColor>skills:</Text> <Text color={SKILL_COLOR}>{agent.skills.join(', ')}</Text>
                </Text>
              )}
            </Box>
          )
        })}
        {perModel.size > 0 && <Text> </Text>}
        {perModel.size > 0 && <Text weight="bold">Per model</Text>}
        {[...perModel.entries()].map(([name, t]) => (
          <Text wrap="truncate-end">
            <Text color={modelColor(name)}>{name}</Text>
            <Text dimColor>
              {' '}
              {compact(t.input + t.cacheRead + t.cacheWrite)} in ({compact(t.cacheRead)} cached) · {compact(t.output)} out
            </Text>
          </Text>
        ))}
        <Text> </Text>
        <Text weight="bold">Dispatch lint</Text>
        <Text dimColor>
          mode {mode} · missing-model {l.lint.missingModel} · opus+low {l.lint.opusLow} · max-effort {l.lint.max}
        </Text>
        {hasUsed && <Text> </Text>}
        {hasUsed && <Text weight="bold">This chat used</Text>}
        {fileRows('files read', readFiles)}
        {fileRows('files written', wroteFiles)}
        {servers.length > 0 && (
          <Text wrap="truncate-end">
            <Text dimColor>MCP calls</Text> {servers.map(([name, n]) => `${name} ${n}`).join(' · ')}
          </Text>
        )}
        {e.surface === 'terminal' && l.timeline.length > 0 && <Text> </Text>}
        {e.surface === 'terminal' && l.timeline.length > 0 && <Text weight="bold">Timeline</Text>}
        {e.surface === 'terminal' &&
          l.timeline.slice(-room).map(m => (
            <Text wrap="truncate-end">
              <Text dimColor>{since(m.at, l.sessionStartedAt).padEnd(8)}</Text>
              <Text color={m.status === null ? undefined : STATUS[m.status].color}>
                {m.status === null ? ' ' : STATUS[m.status].mark}
              </Text>{' '}
              {m.text}
            </Text>
          ))}
      </Box>
    )
  })
}
