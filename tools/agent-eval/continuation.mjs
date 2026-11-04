// 确认后接续这一轮的可靠性对比（docs/agent-tuning-log.md §5）。
// 用真实规模的请求（内置 prompt + 个人食品库 + 全套工具 + 对话历史）对每种参数各跑 N 次，
// 解析 output 里的 function_call（不能搜整段响应文字：响应会原样带回 tools 与 instructions）。
//
// 用法（测试 key 存在本机钥匙串，见 README）：
//   CONDUIT_KEY=$(security find-generic-password -a vita -s vita-chat-test -w) node tools/agent-eval/continuation.mjs [次数]
import { readFileSync } from 'node:fs'

const BASE = process.env.CONDUIT_BASE_URL ?? 'https://conduit.r4s.leonardo-zhu.me'
const KEY = process.env.CONDUIT_KEY
if (!KEY) throw new Error('需要 CONDUIT_KEY（测试用的 vita-chat-test）')
const RUNS = Number(process.argv[2] ?? 20)
const CONCURRENCY = 5

const root = new URL('../../', import.meta.url)
const config = JSON.parse(readFileSync(new URL('shared/config/DefaultConfig.json', root)))
const params = JSON.parse(readFileSync(new URL('shared/agent-tools/tool-parameters.json', root)))
const tools = params.tools.map((t) => ({ type: 'function', name: t.name, description: config.prompts.tools[t.name]?.description ?? '', parameters: t.parameters }))

const MILK_V = '5b0c2f0e-1111-4c1a-9b1e-0000000000a1'
const COFFEE_V = '5b0c2f0e-2222-4c1a-9b1e-0000000000a2'
const instructions = `${config.prompts.system.text}

## 由客户端提供
- 个人食品库（优先于公共参考库；按语义判断用户说的是哪一个，有歧义先问）：
  - 摩可纳 8 号［productId 5b0c2f0e-2222-4c1a-9b1e-000000000002］；品牌 摩可纳；也叫 摩可纳冻干咖啡；包装 100 g；foodVersionId ${COFFEE_V}；每 100 g：321.85 kcal、蛋白质 19.3 g、脂肪 0 g、碳水 59.9 g
  - 小象鲜牛奶［productId 5b0c2f0e-1111-4c1a-9b1e-000000000001］；品牌 小象超市；包装 950 ml；foodVersionId ${MILK_V}；每 100 ml：67.4 kcal、蛋白质 3.3 g、脂肪 3.9 g、碳水 4.8 g、钠 60 mg`
const input = [
  { role: 'user', content: '存进营养库，这个小象的鲜牛奶，它是950ml，就是一大盒这样。然后下午喝了一杯拿铁，2 克摩可纳冻干咖啡加 300ml 这个牛奶\n\n［客户端附件：之前发过 1 张营养标签照片（labelScanId: 9c0e0000-0000-4000-8000-000000000031），已处理过，图片不再附上。］' },
  { role: 'assistant', content: '标签读好了：每 100 ml 67.4 kcal、蛋白质 3.3 g、脂肪 3.9 g、碳水 4.8 g、钠 60 mg。先把小象鲜牛奶存进食品库，确认后我接着记下午的拿铁。' },
  { role: 'system', content: '［系统：上一条助手回复附带一张由提案工具生成的确认卡，用户已确认，已保存。］' },
  { role: 'system', content: '## 当前状态（由客户端提供）\n- 会话日期：2026-11-04（星期三），今天是 2026-11-05。只能写这一天。\n- 现在的本地时间：09:10，时区 Asia/Shanghai。\n- 当天 revision：3。提案时作为 expectedRevision。\n- 当天的记录（修改时用 ID；需要用量与营养细节时调用 getDaySummary）：\n  - lunch［7a1e0000-0000-4000-8000-000000000011］：酸菜鱼［7a1e0000-0000-4000-8000-000000000012］一份' },
  { role: 'system', content: '［客户端：用户刚确认了卡片 3f2a0000-0000-4000-8000-000000000041，已保存。你提案时写下的下一步：按 2 g 摩可纳冻干咖啡 + 300 ml 小象鲜牛奶记录下午的拿铁。现在接着做，数据以上面的当前状态为准；不需要再做就简短说明。］' },
]

const VARIANTS = {
  'low（不强制）': { reasoning: { effort: 'low' } },
  'minimal（不强制）': { reasoning: { effort: 'minimal' } },
  '关思考（不强制）': { thinking: { type: 'disabled' } },
  'low + required': { reasoning: { effort: 'low' }, tool_choice: 'required' },
  '关思考 + required': { thinking: { type: 'disabled' }, tool_choice: 'required' },
}

async function once(extra) {
  const started = Date.now()
  const res = await fetch(`${BASE}/v1/responses`, {
    method: 'POST',
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'vita-chat', store: false, stream: false, instructions, input, tools, ...extra }),
  })
  const body = await res.json()
  const seconds = (Date.now() - started) / 1000
  if (!res.ok || body.error) return { seconds, error: body.error?.code ?? res.status }
  const call = body.output?.find((o) => o.type === 'function_call' && o.name === 'proposeRecordChange')
  let correct = false
  if (call) {
    const payload = JSON.parse(call.arguments).payload ?? {}
    const items = payload.record?.items ?? payload.items ?? []
    const amounts = items.map((i) => i.quantity?.amount).sort((a, b) => a - b)
    const ids = JSON.stringify(items.map((i) => i.nutrition))
    correct = amounts.join() === '2,300' && ids.includes(MILK_V) && ids.includes(COFFEE_V)
  }
  return { seconds, card: Boolean(call), correct, reasoning: body.usage?.output_tokens_details?.reasoning_tokens ?? 0 }
}

for (const [name, extra] of Object.entries(VARIANTS)) {
  const results = []
  for (let i = 0; i < RUNS; i += CONCURRENCY) {
    results.push(...(await Promise.all(Array.from({ length: Math.min(CONCURRENCY, RUNS - i) }, () => once(extra)))))
  }
  const ok = results.filter((r) => !r.error)
  const avg = (key) => (ok.reduce((sum, r) => sum + r[key], 0) / Math.max(ok.length, 1)).toFixed(1)
  console.log(
    `${name}: 出卡 ${ok.filter((r) => r.card).length}/${RUNS}，数量与 ID 都对 ${ok.filter((r) => r.correct).length}，` +
      `平均 ${avg('seconds')} 秒，平均推理 ${avg('reasoning')} token，出错 ${results.length - ok.length}`,
  )
}
