import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { listAudit } from './audit'
import { draftFromBuiltin, knownTools } from './config/model'
import { publish, saveDraft } from './config/service'
import { resetDbForTests } from './db'
import { listTrials, parseResponse, runTrials, sampleContext, trialRequestBody } from './trial'

const actor = { name: 'admin', ip: '127.0.0.1' }

describe('trialRequestBody', () => {
  it('sends the same tools as the app with the draft descriptions', () => {
    const draft = draftFromBuiltin()
    draft.toolDescriptions.getGoals = '改过的描述'
    const body = trialRequestBody(draft, '## 当前状态', '你好')
    expect(body.tools.map((tool) => tool.name)).toEqual(knownTools())
    expect(body.tools.find((tool) => tool.name === 'getGoals')?.description).toBe('改过的描述')
    expect(body.tools.every((tool) => (tool.parameters as { type: string }).type === 'object')).toBe(true)
    expect(body.instructions).toBe(`${draft.systemPrompt}\n\n## 当前状态`)
    expect(body).toMatchObject({ model: draft.llm.modelId, stream: false, store: false })
  })
})

describe('parseResponse', () => {
  it('collects text, reasoning summary, tool calls and usage', () => {
    const parsed = parseResponse({
      output: [
        { type: 'reasoning', summary: [{ text: '先查参考库' }] },
        { type: 'function_call', name: 'searchReferenceFoods', arguments: '{"query":"鸡胸肉"}' },
        { type: 'message', content: [{ type: 'output_text', text: '好的' }] },
      ],
      usage: { input_tokens: 1200, output_tokens: 80 },
    })
    expect(parsed).toEqual({
      output: {
        text: '好的',
        reasoning: '先查参考库',
        toolCalls: [{ name: 'searchReferenceFoods', arguments: '{"query":"鸡胸肉"}' }],
      },
      inputTokens: 1200,
      outputTokens: 80,
    })
  })
})

describe('sampleContext', () => {
  it('follows the app format in Shanghai time', () => {
    const text = sampleContext(new Date('2026-11-01T16:30:00Z'))
    expect(text).toContain('会话日期：2026-11-02（星期一），就是今天')
    expect(text).toContain('现在的本地时间：00:30')
  })
})

describe('runTrials', () => {
  beforeEach(() => {
    process.env.VITA_ADMIN_DATA_DIR = mkdtempSync(path.join(tmpdir(), 'vita-admin-'))
    process.env.CONDUIT_BASE_URL = 'https://conduit.example'
    process.env.CONDUIT_API_KEY = 'test-key'
    resetDbForTests()
  })
  afterEach(() => {
    vi.unstubAllGlobals()
    resetDbForTests()
  })

  it('runs draft and live side by side and records both', async () => {
    publish('', actor)
    saveDraft({ ...draftFromBuiltin(), systemPrompt: '草稿 prompt' }, actor)
    const bodies: { instructions: string }[] = []
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: URL, init: RequestInit) => {
        expect(String(url)).toBe('https://conduit.example/v1/responses')
        expect((init.headers as Record<string, string>).Authorization).toBe('Bearer test-key')
        bodies.push(JSON.parse(String(init.body)))
        return Response.json({ output: [{ type: 'message', content: [{ text: 'ok' }] }] })
      })
    )

    const runs = await runTrials(['live', 'draft'], '中午吃了米饭', '', actor)

    expect(runs.map((run) => run.source).sort()).toEqual(['draft', 'live'])
    expect(bodies.map((body) => body.instructions).sort()).toEqual([draftFromBuiltin().systemPrompt, '草稿 prompt'].sort())
    expect(runs.find((run) => run.source === 'live')?.configVersion).toMatch(/^\d{4}-\d{2}-\d{2}\.\d+$/)
    expect(listTrials()).toHaveLength(2)
    expect(listAudit()[0].action).toBe('trial')
  })

  it('records the error when Conduit fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ error: { message: '额度用完' } }, { status: 429 })))
    const [run] = await runTrials(['draft'], '你好', '', actor)
    expect(run.error).toBe('Conduit 返回 429：额度用完')
    expect(run.output).toBeNull()
  })
})
