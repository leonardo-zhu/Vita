/** 北京时间的今天，`YYYY-MM-DD`（Vita 的日期都按用户本地，Admin 默认按北京时间）。 */
export function todayInShanghai(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai' }).format(new Date())
}

export function isLocalDate(value: string | undefined): value is string {
  return Boolean(value && /^\d{4}-\d{2}-\d{2}$/.test(value))
}

/** ISO 时间 → 北京时间的 `HH:mm` */
export function clock(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso))
}
