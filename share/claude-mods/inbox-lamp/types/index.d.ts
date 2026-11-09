// What the lamp last read from this terminal's kb-msg inbox.
export type Mail = {
  // team:terminal, or null where this session has no kb-msg address.
  address: string | null
  unread: number
  newestFrom: string | null
  newestBody: string | null
  // Unread messages that read like a freeze or merge-order instruction.
  urgentUnread: number
  // Such messages already marked read (a sibling window may have read a
  // team broadcast) within the last 12 hours.
  urgentRecent: number
  checkedAt: number
  error: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'inbox-lamp': { mail: Shaped<Mail>; isOn: boolean }
  }
}
