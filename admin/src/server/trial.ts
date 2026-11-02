/**
 * Prompt 试跑（vita-admin.md §11.1 / §11.2）：用草稿或线上配置，加上和 App 一样的工具定义，
 * 经 Conduit 让模型跑一轮，看它怎么回答、会调用哪个工具、带什么参数。
 *
 * - 只跑第一步：工具不执行（用户数据都在手机上），模型发出的调用原样展示。
 * - 系统指令 = 配置里的系统 prompt；“当前状态”作为系统消息放在用户消息前，和 App 一样。App 里这段由
 *   客户端按真实数据生成（个人食品库在 App 里接在系统指令末尾），这里给一段可编辑的样例（见 sampleContext）。
 * - 推理强度与其他请求参数也按配置带上，模型不接受的参数在这里就会报出来。
 * - 用 Admin 专用的 Conduit 密钥（CONDUIT_API_KEY），不绕过网关。
 */
import 'server-only'

import { randomUUID } from 'node:crypto'

import toolFile from '@/generated/tool-parameters.json'

import { recordAudit } from './audit'
import type { DraftContent } from './config/model'
import { draftFromBuiltin, draftFromPublished } from './config/model'
import { currentRelease, getDraft, type Actor } from './config/service'
import { db, nowSeconds } from './db'

export type TrialSource = 'draft' | 'live'

export interface TrialToolCall {
  name: string
  arguments: string
}

export interface TrialOutput {
  text: string
  reasoning: string
  toolCalls: TrialToolCall[]
}

export interface TrialRun {
  id: number
  batchId: string
  source: TrialSource
  configVersion: string | null
  model: string
  message: string
  context: string
  output: TrialOutput | null
  error: string | null
  requestId: string
  latencyMs: number
  inputTokens: number | null
  outputTokens: number | null
  createdBy: string
  createdAt: number
}

const tools = (toolFile as { tools: { name: string; parameters: unknown }[] }).tools

export function conduitConfigured(): boolean {
  return Boolean(process.env.CONDUIT_BASE_URL && process.env.CONDUIT_API_KEY)
}

/** 和 App 的 ChatOrchestrator.clientState 同样的格式：今天、空记录、空食品库 */
export function sampleContext(now = new Date()): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Shanghai',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      weekday: 'short',
      hour12: false,
    })
      .formatToParts(now)
      .map((part) => [part.type, part.value])
  )
  const weekday = { Sun: '日', Mon: '一', Tue: '二', Wed: '三', Thu: '四', Fri: '五', Sat: '六' }[
    parts.weekday as string
  ]
  const date = `${parts.year}-${parts.month}-${parts.day}`
  return [
    '## 当前状态（由客户端提供）',
    `- 会话日期：${date}（星期${weekday}），就是今天。只能写这一天。`,
    `- 现在的本地时间：${parts.hour}:${parts.minute}，时区 Asia/Shanghai。`,
    '- 当天 revision：0。提案时作为 expectedRevision。',
    '- 当天还没有记录。',
    '- 个人食品库是空的。',
  ].join('\n')
}

function configFor(source: TrialSource): { content: DraftContent; configVersion: string | null } {
  if (source === 'draft') return { content: getDraft().content, configVersion: null }
  const live = currentRelease()
  return live
    ? { content: draftFromPublished(live.content), configVersion: live.config_version }
    : { content: draftFromBuiltin(), configVersion: null }
}

/** App 自己填的字段，其他请求参数不能覆盖；同 iOS 的 RemoteConfigValidator.reservedRequestFields */
const RESERVED_FIELDS = new Set(['model', 'instructions', 'input', 'tools', 'stream', 'store', 'reasoning', 'previous_response_id'])

/** Responses API 的请求体，形状同 iOS 的 ResponsesRequestBody（非流式） */
export function trialRequestBody(content: DraftContent, context: string, message: string) {
  const extra = Object.fromEntries(Object.entries(content.llm.extraBody).filter(([key]) => !RESERVED_FIELDS.has(key)))
  return {
    ...extra,
    model: content.llm.modelId,
    instructions: content.systemPrompt,
    input: [
      ...(context.trim() ? [{ role: 'system', content: context.trim() }] : []),
      { role: 'user', content: message },
    ],
    tools: tools.map((tool) => ({
      type: 'function',
      name: tool.name,
      description: content.toolDescriptions[tool.name] ?? '',
      parameters: tool.parameters,
    })),
    stream: false,
    store: false,
    ...(content.llm.reasoningEffort === 'default' ? {} : { reasoning: { effort: content.llm.reasoningEffort } }),
  }
}

interface ResponsesOutputItem {
  type?: string
  name?: string
  arguments?: string
  content?: { type?: string; text?: string }[]
  summary?: { text?: string }[]
}

/** 从非流式 Responses 结果里取出文字、推理摘要与函数调用 */
export function parseResponse(body: {
  output?: ResponsesOutputItem[]
  usage?: { input_tokens?: number; output_tokens?: number }
}): { output: TrialOutput; inputTokens: number | null; outputTokens: number | null } {
  const output: TrialOutput = { text: '', reasoning: '', toolCalls: [] }
  for (const item of body.output ?? []) {
    if (item.type === 'message') {
      output.text += (item.content ?? []).map((part) => part.text ?? '').join('')
    } else if (item.type === 'reasoning') {
      output.reasoning += (item.summary ?? []).map((part) => part.text ?? '').join('\n')
    } else if (item.type === 'function_call') {
      output.toolCalls.push({ name: item.name ?? '', arguments: item.arguments ?? '' })
    }
  }
  return {
    output,
    inputTokens: body.usage?.input_tokens ?? null,
    outputTokens: body.usage?.output_tokens ?? null,
  }
}

async function callConduit(content: DraftContent, context: string, message: string, requestId: string) {
  const res = await fetch(new URL('/v1/responses', process.env.CONDUIT_BASE_URL), {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.CONDUIT_API_KEY}`,
      'Content-Type': 'application/json',
      'X-Request-Id': requestId,
    },
    body: JSON.stringify(trialRequestBody(content, context, message)),
    // 模型先推理再回答，给到配置里的超时再加一点余量
    signal: AbortSignal.timeout((Math.min(content.llm.timeoutSeconds, 180) + 30) * 1000),
    cache: 'no-store',
  })
  const body = await res.json().catch(() => null)
  if (!res.ok) {
    const detail = (body as { error?: { message?: string } } | null)?.error?.message
    throw new Error(`HTTP ${res.status}${detail ? `: ${detail}` : ''}`)
  }
  return parseResponse(body ?? {})
}

export async function runTrials(
  sources: TrialSource[],
  message: string,
  context: string,
  actor: Actor
): Promise<TrialRun[]> {
  const batchId = randomUUID()
  const runs = await Promise.all(
    sources.map(async (source) => {
      const { content, configVersion } = configFor(source)
      const requestId = randomUUID()
      const started = Date.now()
      try {
        const result = await callConduit(content, context, message, requestId)
        return { source, configVersion, content, requestId, latencyMs: Date.now() - started, ...result, error: null }
      } catch (error) {
        // 存错误码与原始细节，文字由页面按当前语言显示
        const message = (error as Error).name === 'TimeoutError' ? 'timeout' : (error as Error).message
        return {
          source,
          configVersion,
          content,
          requestId,
          latencyMs: Date.now() - started,
          output: null,
          inputTokens: null,
          outputTokens: null,
          error: message,
        }
      }
    })
  )

  const insert = db().prepare(
    `INSERT INTO prompt_trials (batch_id, source, config_version, model, message, context, output, error,
       request_id, latency_ms, input_tokens, output_tokens, created_by, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
  for (const run of runs) {
    insert.run(
      batchId,
      run.source,
      run.configVersion,
      run.content.llm.modelId,
      message,
      context,
      run.output ? JSON.stringify(run.output) : null,
      run.error,
      run.requestId,
      run.latencyMs,
      run.inputTokens,
      run.outputTokens,
      actor.name,
      nowSeconds()
    )
  }
  recordAudit({
    actor: actor.name,
    action: 'trial',
    targetType: 'trial',
    targetId: batchId,
    diff: { sources, messageLength: message.length },
    ip: actor.ip,
  })
  return listTrials(sources.length).filter((run) => run.batchId === batchId)
}

interface TrialRow {
  id: number
  batch_id: string
  source: TrialSource
  config_version: string | null
  model: string
  message: string
  context: string
  output: string | null
  error: string | null
  request_id: string
  latency_ms: number
  input_tokens: number | null
  output_tokens: number | null
  created_by: string
  created_at: number
}

export function listTrials(limit = 40): TrialRun[] {
  const rows = db()
    .prepare('SELECT * FROM prompt_trials ORDER BY id DESC LIMIT ?')
    .all(limit) as unknown as TrialRow[]
  return rows.map((row) => ({
    id: row.id,
    batchId: row.batch_id,
    source: row.source,
    configVersion: row.config_version,
    model: row.model,
    message: row.message,
    context: row.context,
    output: row.output ? (JSON.parse(row.output) as TrialOutput) : null,
    error: row.error,
    requestId: row.request_id,
    latencyMs: row.latency_ms,
    inputTokens: row.input_tokens,
    outputTokens: row.output_tokens,
    createdBy: row.created_by,
    createdAt: row.created_at,
  }))
}
