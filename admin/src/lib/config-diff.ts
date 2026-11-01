/**
 * 两份配置草稿的差异（vita-admin.md §11.2 的版本 diff）。纯函数，页面和客户端组件都能用。
 * 取值类字段给出前后值；prompt 与工具描述给出前后全文，由 TextDiff 按词标出增删。
 */
import type { DraftContent } from '@/server/config/model'

export type DiffEntry =
  | { kind: 'value'; key: string; label: string; from: string; to: string }
  | { kind: 'text'; key: string; label: string; from: string; to: string }

const VALUE_FIELDS: { key: string; label: string; get: (d: DraftContent) => unknown }[] = [
  { key: 'minClientVersion', label: '最低客户端版本', get: (d) => d.minClientVersion },
  { key: 'llm.modelId', label: '模型别名', get: (d) => d.llm.modelId },
  { key: 'llm.timeoutSeconds', label: '超时秒数', get: (d) => d.llm.timeoutSeconds },
  { key: 'llm.maxRetries', label: '重试次数', get: (d) => d.llm.maxRetries },
  { key: 'llm.streaming', label: '流式输出', get: (d) => d.llm.streaming },
  { key: 'context.maxRecentMessages', label: '上下文消息条数', get: (d) => d.context.maxRecentMessages },
  { key: 'context.includePersonalFoodSummary', label: '附带个人食品库', get: (d) => d.context.includePersonalFoodSummary },
]

function show(value: unknown): string {
  if (value === '' || value === undefined) return '（空）'
  if (typeof value === 'boolean') return value ? '开' : '关'
  return String(value)
}

export function configDiff(before: DraftContent, after: DraftContent): DiffEntry[] {
  const entries: DiffEntry[] = []
  for (const field of VALUE_FIELDS) {
    const a = field.get(before)
    const b = field.get(after)
    if (a !== b) entries.push({ kind: 'value', key: field.key, label: field.label, from: show(a), to: show(b) })
  }
  if (before.systemPrompt !== after.systemPrompt) {
    entries.push({ kind: 'text', key: 'systemPrompt', label: '系统 prompt', from: before.systemPrompt, to: after.systemPrompt })
  }
  for (const [name, text] of Object.entries(after.toolDescriptions)) {
    const old = before.toolDescriptions[name] ?? ''
    if (old !== text) {
      entries.push({ kind: 'text', key: `tool:${name}`, label: `工具描述：${name}`, from: old, to: text })
    }
  }
  for (const [name, enabled] of Object.entries(after.features)) {
    if (before.features[name] !== enabled) {
      entries.push({
        kind: 'value',
        key: `feature:${name}`,
        label: `开关 ${name}`,
        from: show(before.features[name]),
        to: show(enabled),
      })
    }
  }
  return entries
}

/** 一行一项的改动摘要，给发布确认框用 */
export function describeChanges(before: DraftContent, after: DraftContent): string[] {
  return configDiff(before, after).map((entry) =>
    entry.kind === 'value' ? `${entry.label}：${entry.from} → ${entry.to}` : entry.label
  )
}
