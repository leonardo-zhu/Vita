/**
 * Agent 的生效配置（vita-admin.md §2、§4，移植自 1.0 的 ConfigResolver）。两层按字段合并：
 * Admin 发布的 stable.json（远程）优先，缺的字段用内置默认值（与 App 同一份 DefaultConfig.json）。
 * 每轮对话开始时读一次，一轮中途不切换；Admin 发布后下一轮就生效，不用发版。
 */
import { readFileSync, statSync } from 'node:fs'

import builtinJson from '../../../ios/Vita/Resources/DefaultConfig.json' with { type: 'json' }
import toolFile from '../../../shared/agent-tools/tool-parameters.json' with { type: 'json' }

export interface PromptText {
  id: string
  version: number
  text: string
}

export interface ToolPrompt {
  version: number
  description: string
}

export interface AgentConfig {
  schemaVersion: number
  configVersion: string
  llm: {
    modelId: string
    timeoutSeconds: number
    maxRetries: number
    streaming: boolean
    /** default 表示不传，用模型自己的默认值。 */
    reasoningEffort: string
    extraBody: Record<string, unknown>
  }
  context: { maxRecentMessages: number; includePersonalFoodSummary: boolean }
  prompts: { system: PromptText; tools: Record<string, ToolPrompt> }
  /** 服务端只用 detail；照片由手机压缩后上传，服务端不再缩放（架构设计 §10）。 */
  labelImage: { maxDimension: number; jpegQuality: number; detail: string }
  features: Record<string, boolean>
}

export const BUILTIN_CONFIG = builtinJson as AgentConfig

/** 工具清单与参数 schema 只随代码发布（shared/agent-tools/tool-parameters.json），远程只能换描述。 */
export const TOOL_SPECS = (toolFile as { tools: { name: string; parameters: unknown }[] }).tools

type DeepPartial<T> = { [K in keyof T]?: T[K] extends object ? (T[K] extends unknown[] ? T[K] : DeepPartial<T[K]>) : T[K] }

/** 远程配置：缺失的字段回落到内置；未知字段忽略。Admin 发布前已按共用 schema 校验过。 */
export type RemoteConfig = DeepPartial<AgentConfig> & { configVersion: string }

export function resolveConfig(builtin: AgentConfig, remote: RemoteConfig | null): AgentConfig {
  if (!remote) return builtin
  const pick = <T>(value: T | undefined, fallback: T): T => (value === undefined || value === null ? fallback : value)
  const tools = { ...builtin.prompts.tools }
  // 只接受已知的工具与开关，未知键忽略。
  for (const [name, prompt] of Object.entries(remote.prompts?.tools ?? {})) {
    if (tools[name] && prompt?.description !== undefined && prompt.version !== undefined) tools[name] = prompt as ToolPrompt
  }
  const features = { ...builtin.features }
  for (const [name, enabled] of Object.entries(remote.features ?? {})) {
    if (name in features && typeof enabled === 'boolean') features[name] = enabled
  }
  const system = remote.prompts?.system
  return {
    schemaVersion: builtin.schemaVersion,
    configVersion: remote.configVersion,
    llm: {
      modelId: pick(remote.llm?.modelId, builtin.llm.modelId),
      timeoutSeconds: pick(remote.llm?.timeoutSeconds, builtin.llm.timeoutSeconds),
      maxRetries: pick(remote.llm?.maxRetries, builtin.llm.maxRetries),
      streaming: pick(remote.llm?.streaming, builtin.llm.streaming),
      reasoningEffort: pick(remote.llm?.reasoningEffort, builtin.llm.reasoningEffort),
      extraBody: pick(remote.llm?.extraBody as Record<string, unknown> | undefined, builtin.llm.extraBody),
    },
    context: {
      maxRecentMessages: pick(remote.context?.maxRecentMessages, builtin.context.maxRecentMessages),
      includePersonalFoodSummary: pick(remote.context?.includePersonalFoodSummary, builtin.context.includePersonalFoodSummary),
    },
    prompts: {
      system: system?.id && system.version !== undefined && system.text !== undefined ? (system as PromptText) : builtin.prompts.system,
      tools,
    },
    labelImage: {
      maxDimension: pick(remote.labelImage?.maxDimension, builtin.labelImage.maxDimension),
      jpegQuality: pick(remote.labelImage?.jpegQuality, builtin.labelImage.jpegQuality),
      detail: pick(remote.labelImage?.detail, builtin.labelImage.detail),
    },
    features,
  }
}

export interface ConfigSource {
  /** 本轮生效的配置。 */
  current(): AgentConfig
}

/**
 * 读 Admin 发布目录里的 stable.json（只读挂载）。按修改时间缓存；文件不存在、读不了或格式不对时用内置默认值，
 * 不影响对话（同 App 拉不到配置时退回内置）。
 */
export class PublishedConfigSource implements ConfigSource {
  private readonly file: string | null
  private cached: { mtimeMs: number; config: AgentConfig } | null = null

  constructor(file: string | null) {
    this.file = file
  }

  current(): AgentConfig {
    if (!this.file) return BUILTIN_CONFIG
    try {
      const { mtimeMs } = statSync(this.file)
      if (this.cached?.mtimeMs !== mtimeMs) {
        const remote = JSON.parse(readFileSync(this.file, 'utf8')) as RemoteConfig
        if (typeof remote.configVersion !== 'string') throw new Error('configVersion missing')
        this.cached = { mtimeMs, config: resolveConfig(BUILTIN_CONFIG, remote) }
      }
      return this.cached.config
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') console.error(`读取发布的配置失败，用内置默认值：${(error as Error).message}`)
      this.cached = null
      return BUILTIN_CONFIG
    }
  }
}

/** 测试用：固定一份配置。 */
export class StaticConfigSource implements ConfigSource {
  private readonly config: AgentConfig
  constructor(config: AgentConfig = BUILTIN_CONFIG) {
    this.config = config
  }
  current(): AgentConfig {
    return this.config
  }
}
