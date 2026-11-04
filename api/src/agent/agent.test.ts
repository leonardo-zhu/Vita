/**
 * 移植自 1.0 的 ChatOrchestratorTests、FoodToolTests 与 ResponsesClientTests：工具循环、确认门、上下文、
 * 标签照片、确认后接续、模型失败与停止，以及流式解析与请求体。模型用按脚本回放的客户端代替。
 */
import { randomUUID } from 'node:crypto'

import type { ChatEvent } from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { NO_TARGETS } from '../services/goals.ts'
import { DAY, NOW, ORIGIN, setup } from '../test/support.ts'
import { BUILTIN_CONFIG, resolveConfig, StaticConfigSource, TOOL_SPECS } from './config.ts'
import { LLMError, mapError, requestBody, StreamParser, type LLMClient, type LLMEvent, type LLMRequest } from './llm.ts'
import { MAX_TOOL_ROUNDS, Orchestrator, type Turn } from './orchestrator.ts'

/** 按脚本回放模型事件，并记下每次请求（深拷贝，之后的修改不影响）。 */
class ScriptedClient implements LLMClient {
  readonly requests: LLMRequest[] = []
  private readonly rounds: (LLMEvent[] | LLMError)[]
  constructor(rounds: (LLMEvent[] | LLMError)[]) {
    this.rounds = rounds
  }
  async *send(request: LLMRequest, signal?: AbortSignal): AsyncIterable<LLMEvent> {
    this.requests.push(structuredClone(request))
    const next = this.rounds.shift() ?? new LLMError('malformedResponse', 'script exhausted')
    if (next instanceof LLMError) throw next
    for (const event of next) {
      signal?.throwIfAborted()
      yield event
    }
  }
}

const done: LLMEvent = { type: 'completed', info: { responseId: null, inputTokens: 100, outputTokens: 20, cachedTokens: 80 } }
const text = (delta: string): LLMEvent => ({ type: 'textDelta', delta })
const call = (callId: string, name: string, args: unknown): LLMEvent => ({
  type: 'functionCall',
  call: { callId, name, arguments: typeof args === 'string' ? args : JSON.stringify(args) },
})

function make(rounds: (LLMEvent[] | LLMError)[]) {
  const context = setup()
  const client = new ScriptedClient(rounds)
  const agent = new Orchestrator({ services: context.services, client, config: new StaticConfigSource() })
  const events: ChatEvent[] = []
  const send = (turn: Turn | string, signal = new AbortController().signal) =>
    agent.run(typeof turn === 'string' ? { kind: 'message', text: turn, labelScanId: null } : turn, DAY, 'device:test', (event) => events.push(event), signal)
  return { ...context, client, agent, events, send }
}

/** 某次请求里工具的输出，按顺序。 */
function outputs(request: LLMRequest): string[] {
  return request.input.flatMap((item) => (item.type === 'functionOutput' ? [item.output] : []))
}

/** 不带 expectedRevision：由服务端补上。 */
const eggProposal = {
  sessionDate: DAY,
  payload: {
    intent: 'create',
    record: {
      eventTime: { precision: 'mealPeriod', mealPeriod: 'lunch' },
      mealLabel: '午餐',
      items: [
        {
          displayName: '水煮蛋',
          originalAmountText: '2 个鸡蛋、共 108g',
          quantity: { amount: 108, unit: 'g' },
          amountSource: 'userMeasured',
          nutrition: { source: 'referenceFood', referenceFoodId: 'vita.reference.egg.whole.boiled' },
        },
      ],
    },
  },
}

describe('工具循环与确认门', () => {
  it('查参考库 → 提出确认卡 → 回复；提案不写正式数据，确认后才写', async () => {
    const { services, client, events, send } = make([
      [{ type: 'reasoning', delta: '先查参考库' }, text('我查一下。'), call('c1', 'searchReferenceFoods', { query: '水煮蛋' }), done],
      [call('c2', 'proposeRecordChange', eggProposal), done],
      [text('请确认这条午餐。'), done],
    ])
    const result = await send('中午吃了 2 个水煮蛋，称了一共 108g')
    expect(result.pendingId).not.toBeNull()
    expect(result.reply).toMatchObject({ role: 'assistant', text: '我查一下。\n\n请确认这条午餐。', cardRef: { type: 'pending', id: result.pendingId } })
    // 推给客户端的文字拼起来与保存的回复一致。
    expect(events.filter((e) => e.type === 'text').map((e) => (e as { delta: string }).delta).join('')).toBe(result.reply.text)
    expect(events[0].type).toBe('started')
    expect(events.filter((e) => e.type === 'step')).toEqual([
      { type: 'step', index: 0, tool: 'searchReferenceFoods', status: 'running' },
      { type: 'step', index: 0, tool: 'searchReferenceFoods', status: 'done' },
      { type: 'step', index: 1, tool: 'proposeRecordChange', status: 'running' },
      { type: 'step', index: 1, tool: 'proposeRecordChange', status: 'done' },
    ])
    expect(services.days.day(DAY).records).toEqual([])

    // 第二轮请求带回了函数调用与输出；查询结果来自服务端。
    const second = client.requests[1]
    expect(second.input).toContainEqual({ type: 'functionCall', call: { callId: 'c1', name: 'searchReferenceFoods', arguments: '{"query":"水煮蛋"}' } })
    expect(outputs(second)[0]).toContain('vita.reference.egg.whole.boiled')

    // 用户在卡片上确认，模型不参与。
    services.pending.confirm(result.pendingId!, ORIGIN)
    expect(services.days.day(DAY).records[0].items[0].quantity).toEqual({ amount: 108, unit: 'g' })
    expect(services.chat.messages(DAY).map((m) => m.role)).toEqual(['user', 'assistant'])
  })

  it('别的日期只提示切换，不写', async () => {
    const { services, send } = make([[call('c1', 'proposeRecordChange', { ...eggProposal, sessionDate: '2026-10-29' }), done], [text('这是昨天的内容，要切到昨天记录吗？'), done]])
    const result = await send('昨天中午吃了两个鸡蛋')
    expect(result.requestedDate).toBe('2026-10-29')
    expect(result.pendingId).toBeNull()
    expect(services.pending.active(DAY)).toBeNull()
    expect(services.pending.active('2026-10-29')).toBeNull()
  })

  it('模型失败时什么都不保存，追踪记下错误', async () => {
    const { services, database, send } = make([new LLMError('authentication')])
    await expect(send('早上喝了牛奶')).rejects.toThrow(LLMError)
    expect(services.chat.messages(DAY)).toEqual([])
    expect(database.prepare('SELECT outcome, error_code FROM chat_traces').get()).toEqual({ outcome: 'error', error_code: 'llm.authentication' })
  })

  it('停止后什么都不保存', async () => {
    const { services, database, send } = make([[text('好'), done]])
    const controller = new AbortController()
    controller.abort()
    await expect(send('你好', controller.signal)).rejects.toThrow()
    expect(services.chat.messages(DAY)).toEqual([])
    expect(database.prepare('SELECT outcome FROM chat_traces').get()).toEqual({ outcome: 'cancelled' })
  })

  it('未知工具和只给客户端的工具被拒绝', async () => {
    const { services, client, send } = make([[call('c1', 'confirmPending', { pendingId: 'x' }), call('c2', 'getGoals', 'not json'), done], [text('好的'), done]])
    await send('确认')
    const results = outputs(client.requests[1])
    expect(results).toHaveLength(2)
    expect(results[0]).toContain('unknownTool')
    expect(results[1]).toContain('malformedArguments')
    expect(services.days.day(DAY).records).toEqual([])
  })

  it('工具来回太多次时停下', async () => {
    const { client, send } = make(Array.from({ length: MAX_TOOL_ROUNDS }, (_, i) => [call(`c${i}`, 'getGoals', {}), done]))
    const result = await send('你好')
    expect(client.requests).toHaveLength(MAX_TOOL_ROUNDS)
    expect(result.reply.text).toContain('步骤太多')
  })
})

describe('上下文', () => {
  it('请求带上配置、本轮状态与历史；状态不进系统指令', async () => {
    const { client, send } = make([[text('第一句回复'), done], [text('第二句回复'), done]])
    await send('你好')
    await send('再说一次')
    const request = client.requests[1]
    expect(request.model).toBe(BUILTIN_CONFIG.llm.modelId)
    expect(request.reasoningEffort).toBe(BUILTIN_CONFIG.llm.reasoningEffort)
    expect(request.instructions.startsWith(BUILTIN_CONFIG.prompts.system.text)).toBe(true)
    // 每轮都变的状态作为系统消息放在本轮消息前，前面的内容才能命中缓存。
    expect(request.instructions).not.toContain('会话日期：')
    expect(request.instructions).toBe(client.requests[0].instructions)
    expect(request.input.slice(0, 2)).toEqual([{ type: 'user', text: '你好' }, { type: 'assistant', text: '第一句回复' }])
    expect(request.input[2]).toMatchObject({ type: 'system' })
    expect((request.input[2] as { text: string }).text).toContain(`会话日期：${DAY}`)
    expect((request.input[2] as { text: string }).text).toContain('revision：0')
    expect(request.input[3]).toEqual({ type: 'user', text: '再说一次' })
    // 只暴露契约里的工具。
    expect(request.tools.map((tool) => tool.name)).toEqual(TOOL_SPECS.map((spec) => spec.name))
    expect(request.tools.map((tool) => tool.name)).not.toContain('confirmPending')
  })

  it('历史里附带确认卡的回复加上卡片结局的注记', async () => {
    const { services, client, send } = make([[call('c1', 'proposeRecordChange', eggProposal), done], [text('请确认卡片。'), done], [text('好'), done]])
    const first = await send('中午两个水煮蛋')
    services.pending.confirm(first.pendingId!, ORIGIN)
    await send('谢谢')
    expect(client.requests[2].input[1]).toEqual({
      type: 'assistant',
      text: '请确认卡片。\n\n［客户端注：这条回复附带一张由提案工具生成的确认卡，用户已确认，已保存。］',
    })
  })

  it('个人食品库整库进系统指令，搜索工具也返回整库', async () => {
    const { services, client, send } = make([[call('c1', 'searchPersonalFoods', { query: '原味的那个脆片' }), done], [text('好的'), done]])
    const productId = services.foods.apply(
      {
        kind: 'createProduct',
        product: { name: '燕麦脆（原味）', brandOrSupplier: null, package: { amount: 300, unit: 'g' }, note: null },
        version: {
          basis: { quantity: { amount: 100, unit: 'g' }, nutrients: { energyKcal: 411, proteinG: 10.5, fatG: 15.2, carbohydrateG: 62 } },
          sourceKind: 'manualEntry',
          labelScanId: null,
          derivedFromReferenceId: null,
          sourceNote: null,
        },
      },
      ORIGIN,
    )
    await send('下午吃了半包原味的那个脆片')
    expect(client.requests[0].instructions).toContain(`燕麦脆（原味）［productId ${productId}］`)
    expect(outputs(client.requests[1])[0]).toContain(productId)
  })

  it('标签照片随消息发给模型，并带上 labelScanId；下一轮重放时照片还在', async () => {
    const { services, client, send } = make([[text('这是什么牌子的？'), done], [text('好的'), done]])
    const labelScanId = services.labels.save(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), 'image/jpeg', ORIGIN)
    await send({ kind: 'message', text: '', labelScanId })
    const sent = client.requests[0].input.at(-1)!
    expect(sent).toMatchObject({ type: 'user', images: [{ dataURL: expect.stringMatching(/^data:image\/jpeg;base64,/), detail: BUILTIN_CONFIG.labelImage.detail }] })
    expect((sent as { text: string }).text).toContain(`labelScanId: ${labelScanId}`)
    expect(services.chat.messages(DAY)[0].cardRef).toEqual({ type: 'label', id: labelScanId })

    await send('是伊利纯牛奶')
    expect(client.requests[1].input[0]).toMatchObject({ type: 'user', images: [{ detail: BUILTIN_CONFIG.labelImage.detail }] })
  })
})

describe('目标与食品库工具', () => {
  it('updateGoal 返回旧值与新值', async () => {
    const { services, client, send } = make([[call('c1', 'updateGoal', { proteinG: 150, userCommand: '把蛋白质目标改成 150g' }), done], [text('已改为 150g。'), done]])
    services.goals.append({ ...NO_TARGETS, energyKcal: 1800, proteinG: 120 }, null, 'manualOnboarding', DAY, ORIGIN)
    const result = await send('把蛋白质目标改成 150g')
    expect(result.goalChanged).toBe(true)
    expect(services.goals.active(DAY)?.targets).toMatchObject({ energyKcal: 1800, proteinG: 150 })
    const output = JSON.parse(outputs(client.requests[1])[0])
    expect(output).toMatchObject({ ok: true, previous: { proteinG: 120 }, current: { proteinG: 150 } })
  })

  it('updateGoal 的固定与随活动计算互斥，幅度有范围', async () => {
    const { services, client, send } = make([
      [call('c1', 'updateGoal', { energyKcal: 2000, goalType: 'lose', userCommand: 'x' }), call('c2', 'updateGoal', { energyPercent: 30, userCommand: 'x' }), done],
      [text('好'), done],
    ])
    const plan = { kind: 'lose' as const, adjustment: { type: 'fraction' as const, value: 0.85 }, bmrKcal: 1700, baselineActivityKcal: 400, baselineEstimated: false }
    services.goals.append({ ...NO_TARGETS, energyKcal: 1870, proteinG: 120 }, plan, 'initialRecommendation', DAY, ORIGIN)
    await send('改目标')
    const [both, tooSteep] = outputs(client.requests[1])
    expect(JSON.parse(both).error.code).toBe('invalidField')
    expect(JSON.parse(tooSteep).error.code).toBe('invalidField')
    expect(services.goals.active(DAY)?.revision).toBe(1)
  })

  it('AI 估算不能存成个人食品；参考库来源的数值从参考库复制', async () => {
    const { services, client, send } = make([
      [
        call('c1', 'proposeFoodChange', {
          sessionDate: DAY,
          payload: { intent: 'createProduct', product: { name: '外卖宫保鸡丁' }, version: { source: 'aiEstimated', basis: { amount: 100, unit: 'g' }, values: { energyKcal: 180, proteinG: 12, fatG: 10, carbohydrateG: 9 } } },
        }),
        call('c2', 'proposeFoodChange', {
          sessionDate: DAY,
          payload: {
            intent: 'createProduct',
            product: { name: '常买的鸡胸肉', package: { amount: 1, unit: '斤' } },
            version: { source: 'referenceDerived', referenceFoodId: 'vita.reference.chicken-breast.raw', values: { energyKcal: 1, proteinG: 99, fatG: 0, carbohydrateG: 0 } },
          },
        }),
        done,
      ],
      [text('好'), done],
    ])
    const result = await send('存一下')
    const [estimate, derived] = outputs(client.requests[1]).map((output) => JSON.parse(output))
    expect(estimate.error.code).toBe('estimateNotAllowed')
    expect(derived.ok).toBe(true)
    const preview = services.pending.get(result.pendingId!).preview
    expect(preview).toMatchObject({ type: 'food', food: { package: { amount: 500, unit: 'g' }, basis: { nutrients: { proteinG: 22.5 } } } })
  })

  it('营养标签来源要指向上传过的照片', async () => {
    const { client, send } = make([
      [
        call('c1', 'proposeFoodChange', {
          sessionDate: DAY,
          payload: { intent: 'createProduct', product: { name: '薯片' }, version: { source: 'nutritionLabel', labelScanId: randomUUID(), basis: { amount: 100, unit: 'g' }, values: { energyKcal: 540, proteinG: 6, fatG: 34, carbohydrateG: 52 } } },
        }),
        done,
      ],
      [text('好'), done],
    ])
    await send('存一下')
    expect(JSON.parse(outputs(client.requests[1])[0]).error.code).toBe('unknownLabel')
  })
})

describe('确认后接续', () => {
  it('确认带下一步的卡片后接着跑一轮，不保存用户消息；只能接续一次', async () => {
    const { services, client, send } = make([
      [call('c1', 'proposeRecordChange', { ...eggProposal, afterConfirm: '再记一杯牛奶' }), done],
      [text('先确认这条午餐，确认后我再记牛奶。'), done],
      [text('接着记牛奶。'), done],
    ])
    const first = await send('中午两个水煮蛋 108g，还喝了一杯牛奶')
    expect(services.pending.get(first.pendingId!).afterConfirm).toBe('再记一杯牛奶')
    expect(() => services.pending.claimContinuation(first.pendingId!)).toThrow('pending.notConfirmed')

    services.pending.confirm(first.pendingId!, ORIGIN)
    const claimed = services.pending.claimContinuation(first.pendingId!)
    expect(claimed).toEqual({ sessionDate: DAY, step: '再记一杯牛奶' })
    expect(() => services.pending.claimContinuation(first.pendingId!)).toThrow('pending.alreadyContinued')

    const next = await send({ kind: 'continuation', pendingId: first.pendingId!, step: claimed.step })
    expect(next.reply.text).toBe('接着记牛奶。')
    // 接续轮把"已确认 + 下一步"作为系统消息放在最后，历史里的卡片注记也已变成已确认。
    const input = client.requests[2].input
    expect(input.at(-1)).toMatchObject({ type: 'system', text: expect.stringContaining('再记一杯牛奶') })
    expect(input.some((item) => item.type === 'assistant' && item.text.includes('用户已确认，已保存'))).toBe(true)
    expect(services.chat.messages(DAY).map((m) => m.role)).toEqual(['user', 'assistant', 'assistant'])
  })
})

describe('配置', () => {
  it('远程配置只能替换已知工具的描述，未知的忽略', () => {
    const config = resolveConfig(BUILTIN_CONFIG, {
      configVersion: '2026-11-04.1',
      prompts: { tools: { getGoals: { version: 9, description: '新描述' }, deleteEverything: { version: 1, description: '不该出现' } } },
      llm: { modelId: 'vita-chat-2' },
    })
    expect(config.configVersion).toBe('2026-11-04.1')
    expect(config.prompts.tools.getGoals.description).toBe('新描述')
    expect(config.prompts.tools).not.toHaveProperty('deleteEverything')
    expect(config.llm).toMatchObject({ modelId: 'vita-chat-2', timeoutSeconds: BUILTIN_CONFIG.llm.timeoutSeconds })
    expect(config.prompts.system).toEqual(BUILTIN_CONFIG.prompts.system)
  })
})

describe('Responses 接口', () => {
  const request: LLMRequest = {
    model: 'vita-chat',
    instructions: '你是 Vita',
    input: [
      { type: 'user', text: '看看', images: [{ dataURL: 'data:image/jpeg;base64,AA==', detail: 'high' }] },
      { type: 'functionCall', call: { callId: 'c1', name: 'getGoals', arguments: '{}' } },
      { type: 'functionOutput', callId: 'c1', output: '{"ok":true}' },
    ],
    tools: [{ name: 'getGoals', description: 'd', parameters: { type: 'object' } }],
    requestId: randomUUID(),
    timeoutSeconds: 60,
    maxRetries: 1,
    streaming: true,
    reasoningEffort: 'low',
    extraBody: { max_output_tokens: 2000, store: true, model: 'other' },
  }

  it('请求体：图片分段、函数调用与输出、额外参数不能覆盖保留字段', () => {
    const body = requestBody(request)
    expect(body).toMatchObject({ model: 'vita-chat', store: false, stream: true, reasoning: { effort: 'low' }, max_output_tokens: 2000 })
    expect((body.input as unknown[])[0]).toEqual({
      role: 'user',
      content: [{ type: 'input_text', text: '看看' }, { type: 'input_image', image_url: 'data:image/jpeg;base64,AA==', detail: 'high' }],
    })
    expect((body.input as unknown[])[1]).toEqual({ type: 'function_call', call_id: 'c1', name: 'getGoals', arguments: '{}' })
    expect((body.input as unknown[])[2]).toEqual({ type: 'function_call_output', call_id: 'c1', output: '{"ok":true}' })
  })

  it('流式解析：文本、推理、函数调用只发一次、完成事件补上漏掉的调用', () => {
    const parser = new StreamParser()
    const line = (event: unknown) => `data: ${JSON.stringify(event)}`
    const events = [
      line({ type: 'response.output_item.added', item: { type: 'reasoning' } }),
      line({ type: 'response.reasoning_summary_text.delta', delta: '想想' }),
      line({ type: 'response.output_text.delta', delta: '你好' }),
      line({ type: 'response.output_item.done', item: { type: 'function_call', call_id: 'c1', name: 'getGoals', arguments: '{}' } }),
      'event: ignored',
      line({
        type: 'response.completed',
        response: {
          id: 'r1',
          output: [
            { type: 'function_call', call_id: 'c1', name: 'getGoals', arguments: '{}' },
            { type: 'function_call', call_id: 'c2', name: 'getHealthSnapshot', arguments: '{}' },
          ],
          usage: { input_tokens: 10, output_tokens: 2, input_tokens_details: { cached_tokens: 8 } },
        },
      }),
    ].flatMap((l) => parser.consume(l))
    parser.finish()
    expect(events.map((e) => e.type)).toEqual(['reasoning', 'reasoning', 'textDelta', 'functionCall', 'functionCall', 'completed'])
    expect(events.at(-1)).toEqual({ type: 'completed', info: { responseId: 'r1', inputTokens: 10, outputTokens: 2, cachedTokens: 8 } })
  })

  it('流中途断开、流内错误与 HTTP 错误各自映射', () => {
    expect(() => new StreamParser().finish()).toThrow('stream ended early')
    expect(() => new StreamParser().consume('data: {"type":"error","code":"upstream_timeout"}')).toThrow(LLMError)
    expect(mapError('insufficient_quota', undefined, 429).code).toBe('quotaExceeded')
    expect(mapError(undefined, undefined, 401).code).toBe('authentication')
    expect(mapError(undefined, 'bad', 400)).toMatchObject({ code: 'invalidRequest', message: 'bad' })
    expect(mapError(undefined, undefined, 504).code).toBe('timeout')
    expect(new LLMError('timeout').retryable).toBe(true)
    expect(new LLMError('authentication').retryable).toBe(false)
  })
})

describe('对话追踪', () => {
  it('记下原话、回复、工具调用与结果、token 数', async () => {
    const { database, send } = make([[call('c1', 'getGoals', {}), done], [text('还没有目标。'), done]])
    await send('我的目标是多少')
    const trace = database.prepare('SELECT * FROM chat_traces').get() as Record<string, unknown>
    expect(trace).toMatchObject({ kind: 'message', input_text: '我的目标是多少', reply: '还没有目标。', outcome: 'ok', rounds: 2, tokens_in: 200, tokens_cached: 160 })
    expect(JSON.parse(trace.steps as string)).toEqual([{ tool: 'getGoals', arguments: '{}', output: expect.stringContaining('还没有每日目标'), resultCode: 'ok' }])
    expect(trace.created_at).toBe(NOW.toISOString())
  })
})
