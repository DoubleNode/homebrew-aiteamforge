import { atom, read, update } from 'claude-code'
import type { EngineInterface, ModelUsage, Register } from 'claude-code'

import type { AgentRec, AgentStatus, Log, Moment } from '../types'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'
import {
  MAIN,
  SKILL_COLOR,
  STATUS,
  compact,
  cut,
  label,
  layoutBand,
  modelColor,
  shortModel,
  since,
  sumTokens,
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
}

// Change the tag when Log's fields change: it declines what an older
// version stored, which outlives a reload.
const log = atom({ plugin: 'agent-watch', key: 'log' } as const, EMPTY, {
  shape: 'log-1',
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

const HELP = [
  '/agent-watch         open the Agents pane',
  '/agent-watch on      turn agent watch on in every chat (remembered)',
  '/agent-watch off     turn it off: no tracking, no band (remembered)',
  '/agent-watch hide    hide the band but keep tracking; /agent-watch show brings it back',
  '/agent-watch clear   forget the agents seen so far',
  '/agent-watch help    this text',
].join('\n')

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
  const skillCalls = new Map<string, number>()
  let spawnsInFlight = 0
  let preloads: string[] = []

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'agent-watch',
      description: 'Agents pane and band: on | off | clear | help',
      argumentHint: '[on|off|clear|help]',
    })
    await sw.start(switchIo($), () => {
      $.ui.invalidate('ui.render')
    })
    const at = await $.clock.now()
    await update($, log, l => (l.sessionStartedAt === 0 ? { ...l, sessionStartedAt: at } : l))

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
        turnSeq: l.turnSeq,
        sessionStartedAt: at,
      }))

      return { text: 'Agent watch cleared.' }
    }
    if (arg === 'help') {
      return { text: HELP }
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
    if (sw.off) return yield* next(e)
    const id = e.agentId ?? MAIN
    const at = await $.clock.now()
    stepsSeen.add(e.turnId)
    if (e.agentId !== undefined) await ensureAgent($, e.agentId, at)
    await update($, log, l => withAgent(l, id, at, a => addModel(a, e.model)))

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

    await update($, log, l => {
      const counted = withAgent(l, id, at, a => ({ ...a, calls: a.calls + 1 }))

      return skill === null ? counted : addSkill(counted, id, skill, at)
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
    if (sw.off) return next(e)
    spawnsInFlight += 1
    let ran
    try {
      ran = await next(e)
    } finally {
      spawnsInFlight -= 1
    }
    const agentId = ran.agentId
    if (ran.deny !== undefined || agentId === undefined) return ran

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
