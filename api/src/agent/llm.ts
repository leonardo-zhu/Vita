/**
 * 模型调用（llm-provider.md，移植自 1.0 的 LLMClient 与 ResponsesClient）。经 Conduit 的 `/v1/responses` 调用：
 * 无状态（`store: false`，上下文每次完整提供）、SSE 流式文本与 function calling。
 * 上层只认识这里的类型，不认识 URL、Bearer 头、SSE 事件名或上游 DTO；工具循环由 orchestrator 驱动。
 */

export interface LLMImage {
  /** `data:image/jpeg;base64,…` */
  dataURL: string
  /** `input_image` 的 detail（low / high / xhigh）。 */
  detail: string
}

export interface LLMFunctionCall {
  callId: string
  name: string
  /** 原始 JSON 文本；由工具解析与校验，不信任其内容。 */
  arguments: string
}

export type LLMInputItem =
  | { type: 'user'; text: string; images?: LLMImage[] }
  /** 放在输入中间的系统消息：每轮都变的状态放这里，不打断前面可缓存的前缀。 */
  | { type: 'system'; text: string }
  | { type: 'assistant'; text: string }
  /** 模型上一步发出的函数调用，回传时须原样带回，才能接上对应的输出。 */
  | { type: 'functionCall'; call: LLMFunctionCall }
  | { type: 'functionOutput'; callId: string; output: string }

export interface LLMToolDefinition {
  name: string
  description: string
  parameters: unknown
}

export interface LLMRequest {
  /** Conduit 的逻辑别名（如 vita-chat）。 */
  model: string
  /** 系统指令：配置里的系统 prompt 加较少变化的上下文（个人食品库），保持稳定才能命中服务商缓存。 */
  instructions: string
  input: LLMInputItem[]
  tools: LLMToolDefinition[]
  /** 同时作为 X-Request-Id，用来和 Conduit 日志对应。 */
  requestId: string
  timeoutSeconds: number
  maxRetries: number
  streaming: boolean
  /** reasoning.effort；null 表示不传。 */
  reasoningEffort: string | null
  /** tool_choice；不给时由模型决定（auto）。确认后的接续第一轮用 required，免得模型只说不做。 */
  toolChoice?: 'auto' | 'required'
  /** 原样合并进请求体的其他参数（配置 llm.extraBody），不能覆盖保留字段。 */
  extraBody: Record<string, unknown>
}

export interface LLMResponseInfo {
  responseId: string | null
  inputTokens: number | null
  outputTokens: number | null
  /** 输入里命中服务商缓存的部分。 */
  cachedTokens: number | null
}

export type LLMEvent =
  /** 推理摘要增量（可能为空，只表示开始推理）。只在生成过程中展示，不回传给模型。 */
  | { type: 'reasoning'; delta: string }
  | { type: 'textDelta'; delta: string }
  | { type: 'functionCall'; call: LLMFunctionCall }
  | { type: 'completed'; info: LLMResponseInfo }

export type LLMErrorCode =
  | 'authentication'
  | 'quotaExceeded'
  | 'invalidRequest'
  | 'upstreamUnavailable'
  | 'upstream'
  | 'timeout'
  | 'network'
  | 'malformedResponse'

/** Conduit 的错误类型加网络错误，各自对应不同的用户提示。message 只有简短说明，不含令牌或请求内容。 */
export class LLMError extends Error {
  readonly code: LLMErrorCode
  constructor(code: LLMErrorCode, message: string = code) {
    super(message)
    this.code = code
  }

  /** 只有还没产出任何事件时才重试，避免重复的文本或工具调用。 */
  get retryable(): boolean {
    return ['upstream', 'upstreamUnavailable', 'timeout', 'network'].includes(this.code)
  }

  get userMessage(): string {
    switch (this.code) {
      case 'authentication':
        return '服务端的模型访问密钥无效或已过期。'
      case 'quotaExceeded':
        return '模型额度已用完，请稍后再试或在 Conduit 调整额度。'
      case 'invalidRequest':
        return `请求没有被接受：${this.message}`
      case 'upstreamUnavailable':
        return '模型服务暂时停用，请稍后再试。'
      case 'upstream':
        return '模型服务出错了，请稍后再试。'
      case 'timeout':
        return '模型响应超时，请再试一次。'
      case 'network':
        return '连不上模型服务，请稍后再试。'
      case 'malformedResponse':
        return '模型返回的内容无法解析，请再试一次。'
    }
  }
}

export interface LLMClient {
  /** 发出一次请求，按到达顺序产出事件。`signal` 中止时抛出 AbortError。 */
  send(request: LLMRequest, signal?: AbortSignal): AsyncIterable<LLMEvent>
}

/** 服务端自己填的字段，extraBody 不能覆盖。 */
export const RESERVED_REQUEST_FIELDS = new Set(['model', 'instructions', 'input', 'tools', 'stream', 'store', 'reasoning', 'previous_response_id', 'tool_choice'])

/** Responses API 请求体。消息用简写形式（role + content），函数调用与输出用 item 形式。 */
export function requestBody(request: LLMRequest): Record<string, unknown> {
  const extra = Object.fromEntries(Object.entries(request.extraBody).filter(([key]) => !RESERVED_REQUEST_FIELDS.has(key)))
  return {
    model: request.model,
    instructions: request.instructions,
    input: request.input.map((item) => {
      switch (item.type) {
        case 'user':
          return item.images?.length
            ? {
                role: 'user',
                content: [
                  { type: 'input_text', text: item.text },
                  ...item.images.map((image) => ({ type: 'input_image', image_url: image.dataURL, detail: image.detail })),
                ],
              }
            : { role: 'user', content: item.text }
        case 'system':
        case 'assistant':
          return { role: item.type, content: item.text }
        case 'functionCall':
          return { type: 'function_call', call_id: item.call.callId, name: item.call.name, arguments: item.call.arguments }
        case 'functionOutput':
          return { type: 'function_call_output', call_id: item.callId, output: item.output }
      }
    }),
    tools: request.tools.map((tool) => ({ type: 'function', name: tool.name, description: tool.description, parameters: tool.parameters })),
    stream: request.streaming,
    // 不让服务商保存回复：上下文每次都完整提供，用不到 previous_response_id。
    store: false,
    ...(request.reasoningEffort ? { reasoning: { effort: request.reasoningEffort } } : {}),
    ...(request.toolChoice ? { tool_choice: request.toolChoice } : {}),
    ...extra,
  }
}

/** Conduit 的 error.type 优先，读不出时按状态码。 */
export function mapError(type: string | undefined, message: string | undefined, status: number): LLMError {
  switch (type) {
    case 'authentication_error':
      return new LLMError('authentication')
    case 'insufficient_quota':
      return new LLMError('quotaExceeded')
    case 'invalid_request_error':
      return new LLMError('invalidRequest', message ?? 'invalid request')
    case 'upstream_unavailable':
      return new LLMError('upstreamUnavailable')
    case 'upstream_timeout':
      return new LLMError('timeout')
    case 'upstream_error':
      return new LLMError('upstream', message ?? 'upstream error')
  }
  if (status === 401 || status === 403) return new LLMError('authentication')
  if (status === 429) return new LLMError('quotaExceeded')
  if (status === 503) return new LLMError('upstreamUnavailable')
  if (status === 504) return new LLMError('timeout')
  if (status >= 400 && status < 500) return new LLMError('invalidRequest', message ?? `HTTP ${status}`)
  return new LLMError('upstream', message ?? `HTTP ${status}`)
}

interface OutputItem {
  type?: string
  call_id?: string
  name?: string
  arguments?: string
  content?: { type?: string; text?: string }[]
}

interface ResponseBody {
  id?: string
  status?: string
  output?: OutputItem[]
  error?: { message?: string }
  usage?: { input_tokens?: number; output_tokens?: number; input_tokens_details?: { cached_tokens?: number } }
}

function info(response: ResponseBody | undefined): LLMResponseInfo {
  return {
    responseId: response?.id ?? null,
    inputTokens: response?.usage?.input_tokens ?? null,
    outputTokens: response?.usage?.output_tokens ?? null,
    cachedTokens: response?.usage?.input_tokens_details?.cached_tokens ?? null,
  }
}

function functionCall(item: OutputItem | undefined): LLMFunctionCall | null {
  if (item?.type !== 'function_call' || !item.call_id || !item.name) return null
  return { callId: item.call_id, name: item.name, arguments: item.arguments ?? '{}' }
}

/** 把 SSE 的 data: 行转成事件。Responses 的每个事件都是一行带 type 的 JSON，逐行解析即可。 */
export class StreamParser {
  private readonly emitted = new Set<string>()
  private completed = false

  consume(line: string): LLMEvent[] {
    if (!line.startsWith('data:')) return []
    const payload = line.slice(5).trim()
    if (!payload || payload === '[DONE]') return []
    let event: {
      type?: string
      delta?: string
      item?: OutputItem
      response?: ResponseBody
      code?: string
      message?: string
      error?: { type?: string; code?: string; message?: string }
    }
    try {
      event = JSON.parse(payload)
    } catch {
      throw new LLMError('malformedResponse', 'event')
    }
    switch (event.type) {
      case 'response.output_text.delta':
        return event.delta ? [{ type: 'textDelta', delta: event.delta }] : []
      case 'response.reasoning_text.delta':
      case 'response.reasoning_summary_text.delta':
        return [{ type: 'reasoning', delta: event.delta ?? '' }]
      case 'response.output_item.added':
        return event.item?.type === 'reasoning' ? [{ type: 'reasoning', delta: '' }] : []
      case 'response.output_item.done':
        return this.emit(functionCall(event.item))
      case 'response.completed':
      case 'response.incomplete': {
        // 个别实现只在完成事件里给出函数调用，这里补上还没发出的。
        this.completed = true
        const calls = (event.response?.output ?? []).flatMap((item) => this.emit(functionCall(item)))
        return [...calls, { type: 'completed', info: info(event.response) }]
      }
      case 'response.failed':
        throw new LLMError('upstream', event.response?.error?.message ?? 'response.failed')
      case 'error': {
        // Conduit 自己的流内错误是 {type, code, message}，上游的可能把细节放在 error 里。
        const code = event.code ?? event.error?.code ?? event.error?.type
        if (code === 'upstream_timeout' || code === 'timeout_error') throw new LLMError('timeout')
        throw new LLMError('upstream', event.message ?? event.error?.message ?? 'stream error')
      }
      default:
        return []
    }
  }

  /** 流结束却没有完成事件，说明连接中途断了。 */
  finish() {
    if (!this.completed) throw new LLMError('malformedResponse', 'stream ended early')
  }

  private emit(call: LLMFunctionCall | null): LLMEvent[] {
    if (!call || this.emitted.has(call.callId)) return []
    this.emitted.add(call.callId)
    return [{ type: 'functionCall', call }]
  }
}

/** 非流式响应：按输出顺序转成同样的事件序列。 */
export function eventsFromResponse(response: ResponseBody): LLMEvent[] {
  if (response.status === 'failed') throw new LLMError('upstream', response.error?.message ?? 'response.failed')
  const events: LLMEvent[] = []
  for (const item of response.output ?? []) {
    const call = functionCall(item)
    if (call) {
      events.push({ type: 'functionCall', call })
    } else if (item.type === 'message') {
      const text = (item.content ?? []).filter((part) => part.type === 'output_text').map((part) => part.text ?? '').join('')
      if (text) events.push({ type: 'textDelta', delta: text })
    }
  }
  return [...events, { type: 'completed', info: info(response) }]
}

/** 唯一的生产实现：经 Conduit 调用。密钥只在服务端，手机上不再有模型相关的密钥（架构设计 §8）。 */
export class ResponsesClient implements LLMClient {
  private readonly baseURL: string
  private readonly apiKey: string
  private readonly retryDelayMs: number

  constructor(baseURL: string, apiKey: string, retryDelayMs = 1000) {
    this.baseURL = baseURL
    this.apiKey = apiKey
    this.retryDelayMs = retryDelayMs
  }

  async *send(request: LLMRequest, signal?: AbortSignal): AsyncIterable<LLMEvent> {
    for (let attempt = 0; ; attempt++) {
      let yielded = false
      try {
        for await (const event of this.perform(request, signal)) {
          yielded = true
          yield event
        }
        return
      } catch (error) {
        if (error instanceof LLMError && error.retryable && !yielded && attempt < request.maxRetries && !signal?.aborted) {
          await new Promise((resolve) => setTimeout(resolve, this.retryDelayMs))
          continue
        }
        throw error
      }
    }
  }

  private async *perform(request: LLMRequest, signal?: AbortSignal): AsyncIterable<LLMEvent> {
    // 流式时是整段生成的上限：模型先推理再回答，给到配置的超时再加余量。
    const timeout = AbortSignal.timeout((request.timeoutSeconds + 30) * 1000)
    let response: Response
    try {
      response = await fetch(new URL('/v1/responses', this.baseURL), {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json',
          'X-Request-Id': request.requestId,
          ...(request.streaming ? { Accept: 'text/event-stream' } : {}),
        },
        body: JSON.stringify(requestBody(request)),
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      })
    } catch (error) {
      throw networkError(error, signal)
    }
    if (!response.ok) {
      const body = (await response.json().catch(() => null)) as { error?: { type?: string; message?: string } } | null
      throw mapError(body?.error?.type, body?.error?.message, response.status)
    }
    try {
      if (!request.streaming) {
        yield* eventsFromResponse((await response.json()) as ResponseBody)
        return
      }
      const parser = new StreamParser()
      const decoder = new TextDecoder()
      let buffer = ''
      for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
        buffer += decoder.decode(chunk, { stream: true })
        const lines = buffer.split(/\r?\n/)
        buffer = lines.pop() ?? ''
        for (const line of lines) yield* parser.consume(line)
      }
      for (const line of (buffer + decoder.decode()).split(/\r?\n/)) yield* parser.consume(line)
      parser.finish()
    } catch (error) {
      if (error instanceof LLMError) throw error
      throw networkError(error, signal)
    }
  }
}

function networkError(error: unknown, signal?: AbortSignal): Error {
  if (signal?.aborted) return signal.reason instanceof Error ? signal.reason : new DOMException('aborted', 'AbortError')
  if (error instanceof Error && error.name === 'TimeoutError') return new LLMError('timeout')
  return new LLMError('network', error instanceof Error ? error.message : String(error))
}
