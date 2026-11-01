/**
 * 两份配置草稿的差异（vita-admin.md §11.2 的版本 diff）。纯函数，页面和客户端组件都能用。
 * 取值类字段给出前后值；prompt 与工具描述给出前后全文，由 TextDiff 按词标出增删。
 * 字段名与取值的文字由界面按当前语言生成（`diffLabel` / `diffValue`）。
 */
import type { Messages } from '@/i18n/messages'
import type { DraftContent } from '@/server/config/model'

export type DiffValue = string | number | boolean | null

export type DiffEntry =
  | { kind: 'value'; key: string; field: ValueField | 'feature'; name?: string; from: DiffValue; to: DiffValue }
  | { kind: 'text'; key: string; field: 'systemPrompt' | 'tool'; name?: string; from: string; to: string }

export type ValueField =
  | 'minClientVersion'
  | 'modelId'
  | 'timeoutSeconds'
  | 'maxRetries'
  | 'streaming'
  | 'maxRecentMessages'
  | 'includePersonalFoodSummary'

const VALUE_FIELDS: { field: ValueField; get: (d: DraftContent) => DiffValue }[] = [
  { field: 'minClientVersion', get: (d) => d.minClientVersion },
  { field: 'modelId', get: (d) => d.llm.modelId },
  { field: 'timeoutSeconds', get: (d) => d.llm.timeoutSeconds },
  { field: 'maxRetries', get: (d) => d.llm.maxRetries },
  { field: 'streaming', get: (d) => d.llm.streaming },
  { field: 'maxRecentMessages', get: (d) => d.context.maxRecentMessages },
  { field: 'includePersonalFoodSummary', get: (d) => d.context.includePersonalFoodSummary },
]

export function configDiff(before: DraftContent, after: DraftContent): DiffEntry[] {
  const entries: DiffEntry[] = []
  for (const { field, get } of VALUE_FIELDS) {
    const a = get(before)
    const b = get(after)
    if (a !== b) entries.push({ kind: 'value', key: field, field, from: a, to: b })
  }
  if (before.systemPrompt !== after.systemPrompt) {
    entries.push({ kind: 'text', key: 'systemPrompt', field: 'systemPrompt', from: before.systemPrompt, to: after.systemPrompt })
  }
  for (const [name, text] of Object.entries(after.toolDescriptions)) {
    const old = before.toolDescriptions[name] ?? ''
    if (old !== text) entries.push({ kind: 'text', key: `tool:${name}`, field: 'tool', name, from: old, to: text })
  }
  for (const [name, enabled] of Object.entries(after.features)) {
    const old = before.features[name] ?? null
    if (old !== enabled) entries.push({ kind: 'value', key: `feature:${name}`, field: 'feature', name, from: old, to: enabled })
  }
  return entries
}

export function diffLabel(t: Messages, entry: DiffEntry): string {
  if (entry.field === 'tool') return t.diff.toolDescription(entry.name ?? '')
  if (entry.field === 'feature') return t.diff.feature(entry.name ?? '')
  if (entry.field === 'systemPrompt') return t.fields.systemPrompt
  return t.fields[entry.field]
}

export function diffValue(t: Messages, value: DiffValue): string {
  if (value === '' || value === null) return t.diff.empty
  if (typeof value === 'boolean') return value ? t.diff.on : t.diff.off
  return String(value)
}

/** 一行一项的改动摘要，给发布确认框用 */
export function describeChanges(t: Messages, before: DraftContent, after: DraftContent): string[] {
  return configDiff(before, after).map((entry) =>
    entry.kind === 'value'
      ? `${diffLabel(t, entry)}${t.common.colon}${diffValue(t, entry.from)} → ${diffValue(t, entry.to)}`
      : diffLabel(t, entry)
  )
}
