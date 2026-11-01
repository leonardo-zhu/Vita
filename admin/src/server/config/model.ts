/**
 * 配置的草稿与发布文件（vita-admin.md §4）。这里只有纯函数，数据库与文件读写在 service.ts。
 *
 * - 草稿（DraftContent）是编辑器里的样子：prompt 只有文字，版本号由发布时计算。
 * - 发布文件（PublishedConfig）就是客户端拉到的 stable.json。
 * - 与内置默认值（ios/Vita/Resources/DefaultConfig.json）文字相同的 prompt 不写进发布文件，
 *   客户端回落到 App 自带的那份；这样 App 更新了内置 prompt，远程没改过的项会跟着更新。
 */
import { z } from 'zod'

import builtinJson from '@/generated/default-config.json'

export const CHANNEL = 'stable'
export const SCHEMA_VERSION = 1

export interface PromptText {
  id: string
  version: number
  text: string
}

export interface ToolPrompt {
  version: number
  description: string
}

/** 内置默认值，形状同 iOS 的 VitaConfig */
export interface BuiltinConfig {
  schemaVersion: number
  configVersion: string
  llm: LLMSettings
  context: ContextSettings
  prompts: { system: PromptText; tools: Record<string, ToolPrompt> }
  features: Record<string, boolean>
}

export interface PublishedConfig {
  schemaVersion: number
  configVersion: string
  minClientVersion?: string
  channel: string
  llm: LLMSettings
  context: ContextSettings
  prompts: { system?: PromptText; tools: Record<string, ToolPrompt> }
  features: Record<string, boolean>
}

const llmSchema = z.object({
  modelId: z.string(),
  timeoutSeconds: z.number().int(),
  maxRetries: z.number().int(),
  streaming: z.boolean(),
})

const contextSchema = z.object({
  maxRecentMessages: z.number().int(),
  includePersonalFoodSummary: z.boolean(),
})

/** 草稿只校验形状，取值范围由发布前的 JSON Schema 校验报告，草稿里可以暂存不合法的值 */
export const draftSchema = z.object({
  minClientVersion: z.string(),
  llm: llmSchema,
  context: contextSchema,
  systemPrompt: z.string(),
  toolDescriptions: z.record(z.string(), z.string()),
  features: z.record(z.string(), z.boolean()),
})

export type LLMSettings = z.infer<typeof llmSchema>
export type ContextSettings = z.infer<typeof contextSchema>
export type DraftContent = z.infer<typeof draftSchema>

export const builtin = builtinJson as BuiltinConfig

/** 客户端认识的工具，顺序同内置默认值。远程只能改这些工具的描述 */
export function knownTools(base: BuiltinConfig = builtin): string[] {
  return Object.keys(base.prompts.tools)
}

export function draftFromBuiltin(base: BuiltinConfig = builtin): DraftContent {
  return {
    minClientVersion: '',
    llm: { ...base.llm },
    context: { ...base.context },
    systemPrompt: base.prompts.system.text,
    toolDescriptions: Object.fromEntries(
      Object.entries(base.prompts.tools).map(([name, tool]) => [name, tool.description])
    ),
    features: { ...base.features },
  }
}

/** 已发布的文件还原成草稿：没写进文件的 prompt 取内置值 */
export function draftFromPublished(
  published: PublishedConfig,
  base: BuiltinConfig = builtin
): DraftContent {
  const draft = draftFromBuiltin(base)
  return {
    ...draft,
    minClientVersion: published.minClientVersion ?? '',
    llm: { ...published.llm },
    context: { ...published.context },
    systemPrompt: published.prompts.system?.text ?? draft.systemPrompt,
    toolDescriptions: {
      ...draft.toolDescriptions,
      ...Object.fromEntries(
        Object.entries(published.prompts.tools).map(([name, tool]) => [name, tool.description])
      ),
    },
    features: { ...draft.features, ...published.features },
  }
}

/** 每个 prompt 用过的最高版本号，键为 `system` 或 `tool:<name>` */
export type PromptVersionHistory = Record<string, number>

export function promptVersionHistory(releases: PublishedConfig[]): PromptVersionHistory {
  const history: PromptVersionHistory = {}
  const bump = (key: string, version: number) => {
    history[key] = Math.max(history[key] ?? 0, version)
  }
  for (const release of releases) {
    if (release.prompts.system) bump('system', release.prompts.system.version)
    for (const [name, tool] of Object.entries(release.prompts.tools)) bump(`tool:${name}`, tool.version)
  }
  return history
}

/**
 * prompt 的版本号：与上一次发布文字相同就沿用；改了就取（内置版本、历史最高版本）中较大的加一，
 * 保证同一版本号只对应一份文字，便于在诊断日志里按版本区分效果。
 */
function promptVersion(
  key: string,
  text: string,
  previous: { version: number; text: string } | undefined,
  builtinVersion: number,
  history: PromptVersionHistory
): number {
  if (previous && previous.text === text) return previous.version
  return Math.max(builtinVersion, history[key] ?? 0) + 1
}

export function buildPublished(
  draft: DraftContent,
  options: {
    configVersion: string
    previous: PublishedConfig | null
    history: PromptVersionHistory
    base?: BuiltinConfig
  }
): PublishedConfig {
  const base = options.base ?? builtin
  const { previous, history } = options

  let system: PromptText | undefined
  if (draft.systemPrompt !== base.prompts.system.text) {
    const prev = previous?.prompts.system
    system = {
      id: base.prompts.system.id,
      version: promptVersion('system', draft.systemPrompt, prev, base.prompts.system.version, history),
      text: draft.systemPrompt,
    }
  }

  const tools: Record<string, ToolPrompt> = {}
  for (const name of knownTools(base)) {
    const description = draft.toolDescriptions[name]
    const builtinTool = base.prompts.tools[name]
    if (description === undefined || description === builtinTool.description) continue
    const prev = previous?.prompts.tools[name]
    tools[name] = {
      version: promptVersion(
        `tool:${name}`,
        description,
        prev && { version: prev.version, text: prev.description },
        builtinTool.version,
        history
      ),
      description,
    }
  }

  const published: PublishedConfig = {
    schemaVersion: SCHEMA_VERSION,
    configVersion: options.configVersion,
    channel: CHANNEL,
    llm: { ...draft.llm },
    context: { ...draft.context },
    prompts: { ...(system ? { system } : {}), tools },
    // 开关只能启用或关闭客户端已有的能力，键以内置默认值为准
    features: Object.fromEntries(
      Object.keys(base.features).map((name) => [name, draft.features[name] ?? base.features[name]])
    ),
  }
  const minClientVersion = draft.minClientVersion.trim()
  if (minClientVersion) published.minClientVersion = minClientVersion
  return published
}

export function sameDraft(a: DraftContent, b: DraftContent): boolean {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b))
}

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, normalize((value as Record<string, unknown>)[key])])
    )
  }
  return value
}

const FIELD_NAMES = {
  minClientVersion: '最低客户端版本',
  'llm.modelId': '模型别名',
  'llm.timeoutSeconds': '超时秒数',
  'llm.maxRetries': '重试次数',
  'llm.streaming': '流式输出',
  'context.maxRecentMessages': '上下文消息条数',
  'context.includePersonalFoodSummary': '附带个人食品库',
} as const

/** 两份草稿之间改了什么，给发布确认框与发布历史看 */
export function describeChanges(before: DraftContent, after: DraftContent): string[] {
  const changes: string[] = []
  const show = (value: unknown) =>
    value === '' ? '（空）' : typeof value === 'boolean' ? (value ? '开' : '关') : String(value)
  const scalar = (key: keyof typeof FIELD_NAMES, a: unknown, b: unknown) => {
    if (a !== b) changes.push(`${FIELD_NAMES[key]}：${show(a)} → ${show(b)}`)
  }
  scalar('minClientVersion', before.minClientVersion, after.minClientVersion)
  scalar('llm.modelId', before.llm.modelId, after.llm.modelId)
  scalar('llm.timeoutSeconds', before.llm.timeoutSeconds, after.llm.timeoutSeconds)
  scalar('llm.maxRetries', before.llm.maxRetries, after.llm.maxRetries)
  scalar('llm.streaming', before.llm.streaming, after.llm.streaming)
  scalar('context.maxRecentMessages', before.context.maxRecentMessages, after.context.maxRecentMessages)
  scalar(
    'context.includePersonalFoodSummary',
    before.context.includePersonalFoodSummary,
    after.context.includePersonalFoodSummary
  )
  if (before.systemPrompt !== after.systemPrompt) changes.push('系统 prompt')
  for (const [name, text] of Object.entries(after.toolDescriptions)) {
    if (before.toolDescriptions[name] !== text) changes.push(`工具描述：${name}`)
  }
  for (const [name, enabled] of Object.entries(after.features)) {
    if (before.features[name] !== enabled) changes.push(`开关 ${name}：${show(before.features[name])} → ${show(enabled)}`)
  }
  return changes
}
