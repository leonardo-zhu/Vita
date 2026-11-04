/**
 * 一轮对话：组装请求、驱动工具循环、保存对话与追踪（TDD §5.1，移植自 1.0 的 ChatOrchestrator）。
 * 模型只能查询与提案；确认由用户在卡片上操作，模型拿不到 confirm。每轮开始时读取一次生效配置，一轮中途不切换。
 */
import { randomUUID } from 'node:crypto'

import type { CardRef, ChatEvent, ChatMessage } from '@vita/contract'

import { localDateOf, localParts, addDays } from '../domain/time.ts'
import type { Services } from '../services/index.ts'
import type { AgentConfig, ConfigSource } from './config.ts'
import { TOOL_SPECS } from './config.ts'
import { LLMError, type LLMClient, type LLMImage, type LLMInputItem } from './llm.ts'
import { ToolRunner } from './tools.ts'

/** 一轮里最多来回几次工具调用，防止模型陷入循环。 */
export const MAX_TOOL_ROUNDS = 8
/** 对话追踪保留多久（架构设计 §10.3）。 */
const TRACE_RETENTION_DAYS = 90

/** 本轮交给模型的：用户消息会保存进对话；确认后的接续不保存用户消息。 */
export type Turn =
  | { kind: 'message'; text: string; labelScanId: string | null }
  | { kind: 'continuation'; pendingId: string; step: string }

export interface TurnResult {
  reply: ChatMessage
  pendingId: string | null
  requestedDate: string | null
  goalChanged: boolean
}

interface Step {
  tool: string
  arguments: string
  output: string
  resultCode: string
}

export interface AgentDependencies {
  services: Services
  client: LLMClient
  config: ConfigSource
}

export class Orchestrator {
  private readonly deps: AgentDependencies
  private readonly tools: ToolRunner

  constructor(deps: AgentDependencies) {
    this.deps = deps
    this.tools = new ToolRunner(deps.services)
  }

  /**
   * 跑完工具循环后一起保存用户消息与回复。模型调用失败或被取消时什么都不保存（这一轮里已经生成的确认卡保留：
   * 它不是正式数据，用户仍可确认或取消），抛出错误，由调用方告诉客户端把原文放回输入框。
   */
  async run(turn: Turn, date: string, actor: string, emit: (event: ChatEvent) => void, signal: AbortSignal, requestId = randomUUID()): Promise<TurnResult> {
    const { services, client } = this.deps
    const { chat } = services
    const started = Date.now()
    const config = this.deps.config.current()
    this.purgeTraces()
    services.pending.expireDue()
    emit({ type: 'started', requestId })

    const input = this.historyInput(chat.messages(date), config)
    input.push({ type: 'system', text: this.clientState(date) })
    const turnText = turn.kind === 'message' ? turn.text : continuationNote(turn.pendingId, turn.step)
    input.push(turn.kind === 'message' ? this.userItem(turn.text, turn.labelScanId, config) : { type: 'system', text: turnText })
    const instructions = this.instructions(config)
    const definitions = TOOL_SPECS.map((spec) => ({ name: spec.name, description: config.prompts.tools[spec.name]?.description ?? '', parameters: spec.parameters }))

    let reply = ''
    let reasoning = ''
    const steps: Step[] = []
    let pendingId: string | null = null
    let requestedDate: string | null = null
    let goalChanged = false
    const usage = { rounds: 0, tokensIn: null as number | null, tokensOut: null as number | null, tokensCached: null as number | null, hitMaxRounds: false }
    const add = (current: number | null, value: number | null) => (value === null ? current : (current ?? 0) + value)

    const trace = (outcome: 'ok' | 'error' | 'cancelled', errorCode: string | null) =>
      this.saveTrace({
        requestId, date, kind: turn.kind, config, inputText: turnText,
        labelScanId: turn.kind === 'message' ? turn.labelScanId : null,
        reply, reasoning, steps, pendingId, outcome, errorCode, usage, latencyMs: Date.now() - started,
      })

    try {
      for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
        usage.rounds = round + 1
        let roundText = ''
        const calls = []
        const stream = client.send(
          {
            model: config.llm.modelId,
            instructions,
            input,
            tools: definitions,
            requestId: round === 0 ? requestId : randomUUID(),
            timeoutSeconds: config.llm.timeoutSeconds,
            maxRetries: config.llm.maxRetries,
            streaming: config.llm.streaming,
            reasoningEffort: config.llm.reasoningEffort === 'default' ? null : config.llm.reasoningEffort,
            extraBody: config.llm.extraBody,
          },
          signal,
        )
        for await (const event of stream) {
          switch (event.type) {
            case 'reasoning':
              reasoning += event.delta
              emit({ type: 'reasoning', delta: event.delta })
              break
            case 'textDelta':
              // 不同轮之间的文字用空行隔开，与保存的回复一致。
              emit({ type: 'text', delta: !roundText && reply ? '\n\n' + event.delta : event.delta })
              roundText += event.delta
              break
            case 'functionCall':
              calls.push(event.call)
              break
            case 'completed':
              usage.tokensIn = add(usage.tokensIn, event.info.inputTokens)
              usage.tokensOut = add(usage.tokensOut, event.info.outputTokens)
              usage.tokensCached = add(usage.tokensCached, event.info.cachedTokens)
              break
          }
        }
        reply = join(reply, roundText)
        if (roundText) input.push({ type: 'assistant', text: roundText })
        if (calls.length === 0) break

        for (const call of calls) {
          const index = steps.length
          emit({ type: 'step', index, tool: call.name, status: 'running' })
          const outcome = this.tools.run(call, date, requestId, actor)
          steps.push({ tool: call.name, arguments: call.arguments, output: outcome.output, resultCode: outcome.resultCode })
          emit({ type: 'step', index, tool: call.name, status: outcome.resultCode === 'ok' ? 'done' : 'failed' })
          input.push({ type: 'functionCall', call }, { type: 'functionOutput', callId: call.callId, output: outcome.output })
          // afterConfirm 已随确认卡保存，确认后由 /continue 接续。
          if (outcome.pendingId) pendingId = outcome.pendingId
          if (outcome.requestedDate) requestedDate = outcome.requestedDate
          goalChanged ||= outcome.goalChanged
        }
        if (round === MAX_TOOL_ROUNDS - 1) {
          usage.hitMaxRounds = true
          const note = '这次处理步骤太多，我先停在这里。请换个说法再试一次。'
          emit({ type: 'text', delta: reply ? '\n\n' + note : note })
          reply = join(reply, note)
        }
      }
      signal.throwIfAborted()
    } catch (error) {
      const cancelled = signal.aborted
      trace(cancelled ? 'cancelled' : 'error', cancelled ? null : error instanceof LLMError ? `llm.${error.code}` : 'app.unexpected')
      throw error
    }

    if (!reply.trim()) {
      reply = pendingId ? '请确认下面的卡片。' : '好的。'
      emit({ type: 'text', delta: reply })
    }
    if (turn.kind === 'message') {
      chat.append(date, 'user', turn.text, turn.labelScanId ? { type: 'label', id: turn.labelScanId } : null)
    }
    const saved = chat.append(date, 'assistant', reply, pendingId ? { type: 'pending', id: pendingId } : null)
    trace('ok', null)
    return { reply: saved, pendingId, requestedDate, goalChanged }
  }

  // MARK: - 上下文

  /**
   * 最近的若干条用户与助手文字。工具调用不重放，模型需要时再查。附带确认卡的回复后面加一句注记，
   * 让模型看到卡片只来自工具、以及它的结局；带营养标签的用户消息重放时照片一起带上。
   */
  private historyInput(history: ChatMessage[], config: AgentConfig): LLMInputItem[] {
    const limit = Math.max(config.context.maxRecentMessages, 0)
    return (limit === 0 ? [] : history.slice(-limit)).map((message): LLMInputItem => {
      if (message.role === 'user') {
        return message.cardRef?.type === 'label' ? this.userItem(message.text, message.cardRef.id, config) : { type: 'user', text: message.text }
      }
      if (message.cardRef?.type !== 'pending') return { type: 'assistant', text: message.text }
      return { type: 'assistant', text: `${message.text}\n\n［客户端注：这条回复附带一张由提案工具生成的确认卡，${this.cardStatus(message.cardRef)}。］` }
    })
  }

  private cardStatus(ref: CardRef): string {
    try {
      switch (this.deps.services.pending.get(ref.id).status) {
        case 'confirmed':
          return '用户已确认，已保存'
        case 'cancelled':
          return '用户已取消，没有保存'
        case 'expired':
          return '已过期，没有保存'
        case 'readyForConfirmation':
          return '等待用户确认'
      }
    } catch {
      return '等待用户确认'
    }
  }

  /** 用户消息；附带标签照片时在文字后注明 labelScanId，照片作为图片输入。照片读不到时只留说明。 */
  private userItem(text: string, labelScanId: string | null, config: AgentConfig): LLMInputItem {
    if (!labelScanId) return { type: 'user', text }
    const image = this.labelImage(labelScanId, config)
    const note = image
      ? `［客户端附件：营养标签照片，labelScanId: ${labelScanId}］`
      : `［客户端附件：营养标签照片，labelScanId: ${labelScanId}；照片已无法读取］`
    const body = text ? `${text}\n\n${note}` : note
    return image ? { type: 'user', text: body, images: [image] } : { type: 'user', text: body }
  }

  private labelImage(id: string, config: AgentConfig): LLMImage | null {
    const file = this.deps.services.labels.read(id)
    if (!file) return null
    return { dataURL: `data:${file.contentType};base64,${file.bytes.toString('base64')}`, detail: config.labelImage.detail }
  }

  /**
   * 本轮的状态，作为系统消息放在本轮消息前：会话日期由客户端的导航决定，模型不能自己推断。
   * 时间、revision 与当天记录每轮都会变，放在系统指令里会让后面的内容都无法命中缓存。
   */
  clientState(date: string): string {
    const { services } = this.deps
    const { now, timeZone } = services.context
    const zone = timeZone()
    const today = localDateOf(now(), zone)
    const day = services.days.day(date)
    const pending = services.pending.active(date)
    const parts = localParts(now(), zone)
    const weekday = '日一二三四五六'[new Date(`${date}T00:00:00Z`).getUTCDay()]
    const lines = [
      '## 当前状态（由客户端提供）',
      `- 会话日期：${date}（星期${weekday}）${date === today ? '，就是今天' : `，今天是 ${today}`}。只能写这一天。`,
      `- 现在的本地时间：${String(parts.hour).padStart(2, '0')}:${String(parts.minute).padStart(2, '0')}，时区 ${zone}。`,
      `- 当天 revision：${day.revision}。提案时作为 expectedRevision。`,
    ]
    if (pending) {
      lines.push(`- 当天有一张待确认卡片：${pending.id}。修正它时填 replacesPendingId；用户要记别的内容，先请用户确认或取消这张卡片。`)
    }
    if (day.records.length === 0) {
      lines.push('- 当天还没有记录。')
    } else {
      lines.push('- 当天的记录（修改时用 ID；需要用量与营养细节时调用 getDaySummary）：')
      for (const record of day.records) {
        const label = record.mealLabel ?? record.eventTime.mealPeriod ?? record.eventTime.precision
        const items = record.items.map((item) => `${item.displayName}［${item.id}］${item.originalAmountText}`).join('；')
        lines.push(`  - ${label}［${record.id}］：${items}`)
      }
    }
    return lines.join('\n')
  }

  /** 系统指令：配置里的系统 prompt 加个人食品库。食品库只在用户确认新食品后变化，适合留在可缓存的前缀里。 */
  instructions(config: AgentConfig): string {
    if (!config.context.includePersonalFoodSummary) return config.prompts.system.text
    // 整库注入，由模型做语义匹配，不做模糊匹配（ADR-015）。
    const products = this.deps.services.foods.products()
    const lines =
      products.length === 0
        ? ['- 个人食品库是空的。']
        : [
            '- 个人食品库（优先于公共参考库；按语义判断用户说的是哪一个，有歧义先问）：',
            ...products.map((product) => {
              const parts = [`${product.name}［productId ${product.id}］`]
              if (product.brandOrSupplier) parts.push(`品牌 ${product.brandOrSupplier}`)
              if (product.package) parts.push(`包装 ${product.package.amount} ${product.package.unit}`)
              const version = product.activeVersion
              if (version) {
                const { quantity, nutrients: n } = version.basis
                parts.push(`foodVersionId ${version.id}`)
                parts.push(`每 ${quantity.amount} ${quantity.unit}：${n.energyKcal} kcal、蛋白质 ${n.proteinG} g、脂肪 ${n.fatG} g、碳水 ${n.carbohydrateG} g`)
              }
              return '  - ' + parts.join('；')
            }),
          ]
    return `${config.prompts.system.text}\n\n## 由客户端提供\n${lines.join('\n')}`
  }

  // MARK: - 对话追踪

  private saveTrace(trace: {
    requestId: string
    date: string
    kind: Turn['kind']
    config: AgentConfig
    inputText: string
    labelScanId: string | null
    reply: string
    reasoning: string
    steps: Step[]
    pendingId: string | null
    outcome: 'ok' | 'error' | 'cancelled'
    errorCode: string | null
    usage: { rounds: number; tokensIn: number | null; tokensOut: number | null; tokensCached: number | null; hitMaxRounds: boolean }
    latencyMs: number
  }) {
    const { usage } = trace
    this.deps.services.context.database
      .prepare(
        `INSERT INTO chat_traces (request_id, session_date, kind, config_version, system_prompt_version, model, input_text, label_scan_id, reply, reasoning,
           steps, pending_id, outcome, error_code, rounds, tokens_in, tokens_out, tokens_cached, hit_max_rounds, latency_ms, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        trace.requestId,
        trace.date,
        trace.kind === 'message' ? 'message' : 'continuation',
        trace.config.configVersion,
        trace.config.prompts.system.version,
        trace.config.llm.modelId,
        trace.inputText,
        trace.labelScanId,
        trace.reply || null,
        trace.reasoning || null,
        JSON.stringify(trace.steps),
        trace.pendingId,
        trace.outcome,
        trace.errorCode,
        usage.rounds,
        usage.tokensIn,
        usage.tokensOut,
        usage.tokensCached,
        usage.hitMaxRounds ? 1 : 0,
        trace.latencyMs,
        this.deps.services.context.now().toISOString(),
      )
  }

  private purgeTraces() {
    const { now, timeZone } = this.deps.services.context
    const cutoff = addDays(localDateOf(now(), timeZone()), -TRACE_RETENTION_DAYS)
    this.deps.services.context.database.prepare('DELETE FROM chat_traces WHERE created_at < ?').run(cutoff)
  }
}

/** 确认了一张带 afterConfirm 的卡片后接着跑一轮：把"已确认、下一步是什么"作为系统消息交给模型。 */
function continuationNote(pendingId: string, step: string): string {
  return `［客户端：用户刚确认了卡片 ${pendingId}，已保存。你提案时写下的下一步：${step}。现在接着做，数据以上面的当前状态为准；不需要再做就简短说明。］`
}

function join(first: string, second: string): string {
  if (!first) return second
  if (!second) return first
  return `${first}\n\n${second}`
}
