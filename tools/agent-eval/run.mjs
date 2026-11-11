// 固定评测用例：把出过问题的真实对话做成用例，改 prompt、换模型、调参数前后各跑一遍（docs/agent-tuning-log.md §8）。
// 每个用例只看模型的第一次回应（服务端的兜底不参与），判断它是否“一次做对”。
//
// 用法：
//   sh tools/agent-eval/fetch-fixtures.sh        # 首次：拷真实标签照片到 fixtures/（不进 git）
//   CONDUIT_KEY=$(security find-generic-password -a vita -s vita-chat-test -w) \
//     node tools/agent-eval/run.mjs [--runs 5] [--model vita-chat,another-alias] [--case 名称片段] [--effort low]
import { existsSync, readFileSync } from 'node:fs'

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, index, all) => (arg.startsWith('--') ? [...pairs, [arg.slice(2), all[index + 1]]] : pairs), []),
)
const BASE = process.env.CONDUIT_BASE_URL ?? 'https://conduit.r4s.leonardo-zhu.me'
const KEY = process.env.CONDUIT_KEY
if (!KEY) throw new Error('需要 CONDUIT_KEY（测试用的 vita-chat-test）')
const RUNS = Number(args.runs ?? 5)
const MODELS = (args.model ?? 'vita-chat').split(',')
const EFFORT = args.effort ?? 'low'
const CONCURRENCY = 5

const root = new URL('../../', import.meta.url)
const config = JSON.parse(readFileSync(new URL('shared/config/DefaultConfig.json', root)))
const params = JSON.parse(readFileSync(new URL('shared/agent-tools/tool-parameters.json', root)))
const tools = params.tools.map((t) => ({ type: 'function', name: t.name, description: config.prompts.tools[t.name]?.description ?? '', parameters: t.parameters }))

// MARK: - 上下文素材（形状与 api/src/agent/orchestrator.ts 拼出来的一致）

const MILK = { product: '5b0c2f0e-1111-4c1a-9b1e-000000000001', version: '5b0c2f0e-1111-4c1a-9b1e-0000000000a1' }
const COFFEE = { product: '5b0c2f0e-2222-4c1a-9b1e-000000000002', version: '5b0c2f0e-2222-4c1a-9b1e-0000000000a2' }
const EGG = { product: '5b0c2f0e-3333-4c1a-9b1e-000000000003', version: '5b0c2f0e-3333-4c1a-9b1e-0000000000a3' }
const LIBRARY_LINES = {
  milk: `  - 小象鲜牛奶［productId ${MILK.product}］；品牌 小象超市；包装 950 ml；foodVersionId ${MILK.version}；每 100 ml：67.4 kcal、蛋白质 3.3 g、脂肪 3.9 g、碳水 4.8 g、钠 60 mg`,
  coffee: `  - 摩可纳 8 号［productId ${COFFEE.product}］；品牌 摩可纳；也叫 摩可纳冻干咖啡；包装 100 g；foodVersionId ${COFFEE.version}；每 100 g：321.85 kcal、蛋白质 19.3 g、脂肪 0 g、碳水 59.9 g`,
  egg: `  - 水煮蛋［productId ${EGG.product}］；包装 1 个 50 g；foodVersionId ${EGG.version}；每 100 g：144 kcal、蛋白质 13.3 g、脂肪 8.8 g、碳水 2.8 g`,
}

function instructions(library) {
  const lines = library.length
    ? ['- 个人食品库（优先于公共参考库；按语义判断用户说的是哪一个，有歧义先问）：', ...library.map((key) => LIBRARY_LINES[key])]
    : ['- 个人食品库是空的。']
  return `${config.prompts.system.text}\n\n## 由客户端提供\n${lines.join('\n')}`
}

function state({ date = '2026-11-05', revision = 0, records = [] } = {}) {
  return {
    role: 'system',
    content: [
      '## 当前状态（由客户端提供）',
      `- 会话日期：${date}（星期四），就是今天。只能写这一天。`,
      '- 现在的本地时间：08:30，时区 Asia/Shanghai。',
      `- 当天 revision：${revision}。提案时作为 expectedRevision。`,
      records.length ? '- 当天的记录（修改时用 ID；需要用量与营养细节时调用 getDaySummary）：' : '- 当天还没有记录。',
      ...records,
    ].join('\n'),
  }
}

function photo(name) {
  const file = new URL(`fixtures/${name}.jpeg`, import.meta.url)
  if (!existsSync(file)) return null
  return { type: 'input_image', image_url: `data:image/jpeg;base64,${readFileSync(file).toString('base64')}`, detail: config.labelImage.detail }
}

function userWithPhoto(text, name, labelScanId) {
  const image = photo(name)
  if (!image) return null
  const note = `［客户端附件：营养标签照片，labelScanId: ${labelScanId}］`
  return { role: 'user', content: [{ type: 'input_text', text: `${text}\n\n${note}` }, image] }
}

/** 参数不是合法 JSON 时 args 为 null（服务端会以 malformedArguments 拒绝），用例按失败算。 */
function parseArgs(raw) {
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}
const calls = (body) => (body.output ?? []).filter((o) => o.type === 'function_call').map((o) => ({ name: o.name, args: parseArgs(o.arguments) }))
const malformed = (body) => calls(body).some((c) => c.args === null)
const text = (body) =>
  (body.output ?? [])
    .filter((o) => o.type === 'message')
    .flatMap((o) => o.content ?? [])
    .map((c) => c.text ?? '')
    .join('')
const foodProposal = (body) => calls(body).find((c) => c.name === 'proposeFoodChange')?.args?.payload

const searchTurn = (id, query, match) => [
  { type: 'function_call', call_id: id, name: 'searchReferenceFoods', arguments: JSON.stringify({ query }) },
  { type: 'function_call_output', call_id: id, output: JSON.stringify({ matches: [match] }) },
]
const OIL_SEARCH = searchTurn('call_oil', '植物油', { referenceFoodId: 'vita.reference.oil.soybean', name: '大豆油', aliases: ['大豆油', '豆油'], preparationState: 'asSold', per100g: { energyKcal: 899, proteinG: 0, fatG: 99.9, carbohydrateG: 0 } })

// MARK: - 用例：每个都来自一次真实出过的问题

const CASES = [
  {
    name: '接续：牛奶确认后记拿铁',
    source: '2026-11-05 接续轮只说“现在记……”不调工具（§8.3）',
    build: () => ({
      instructions: instructions(['coffee', 'milk']),
      input: [
        { role: 'user', content: '存进营养库，这个小象的鲜牛奶，它是950ml。然后下午喝了一杯拿铁，2 克摩可纳冻干咖啡加 300ml 这个牛奶' },
        { role: 'assistant', content: '标签读好了。先把小象鲜牛奶存进食品库，确认后我接着记下午的拿铁。' },
        { role: 'system', content: '［系统：上一条助手回复附带一张由提案工具生成的确认卡，用户已确认，已保存。］' },
        state({ date: '2026-11-05', revision: 1, records: ['  - breakfast［7a1e0000-0000-4000-8000-000000000011］：猪肉小笼包［7a1e0000-0000-4000-8000-000000000012］一袋'] }),
        { role: 'system', content: '［客户端：用户刚确认了卡片 3f2a0000-0000-4000-8000-000000000041，已保存。你提案时写下的下一步：按 2 g 摩可纳冻干咖啡 + 300 ml 小象鲜牛奶记录下午的拿铁。现在接着做，数据以上面的当前状态为准；不需要再做就简短说明。］' },
      ],
      toolChoice: 'required',
    }),
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      if (!call) return [false, `没出卡：${text(body).slice(0, 50)}`]
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      const amounts = items.map((i) => i.quantity?.amount).sort((a, b) => a - b).join()
      const ids = JSON.stringify(items.map((i) => i.nutrition))
      return amounts === '2,300' && ids.includes(MILK.version) && ids.includes(COFFEE.version) ? [true] : [false, `用量或 ID 不对：${amounts}`]
    },
  },
  {
    name: '标签缺净含量：小笼汤包',
    source: '2026-11-05 存了没有净含量的食品，按“一袋”记不了',
    build: () => {
      const message = userWithPhoto('先记录这个小笼汤包，然后我今天早上也刚吃完这一袋', 'xiaolongbao', '47803f31-d358-443e-9805-906680efda59')
      return message && { instructions: instructions(['milk', 'coffee']), input: [state(), message] }
    },
    check(body) {
      const payload = foodProposal(body)
      // 照片里净含量看不清（实际是 288 g、12 只）：应该先问；读出了就必须是 288 g，编一个算错。
      if (!payload) return /克|净含量|多重|多少|几只/.test(text(body)) ? [true, '先问了'] : [false, `既没提案也没问：${text(body).slice(0, 50)}`]
      const pack = payload.product?.package
      if (!pack) return [false, '提案没带净含量（服务端会拒绝）']
      return pack.amount === 288 && pack.unit === 'g' ? [true, '读出了 288 g'] : [false, `净含量编成了 ${pack.amount} ${pack.unit}`]
    },
  },
  {
    name: '名称简短：摩可纳咖啡',
    source: '2026-11-05 名称照抄标签全称“经典8号深度烘焙冻干速溶咖啡固体饮料”',
    build: () => {
      const message = userWithPhoto('存一下这个摩可纳的冻干咖啡', 'coffee', 'd9fea46e-94b5-44ac-9c94-1c695e226f11')
      return message && { instructions: instructions(['milk']), input: [state(), message] }
    },
    check(body) {
      const payload = foodProposal(body)
      if (!payload) return [false, `没提案：${text(body).slice(0, 50)}`]
      const name = payload.product?.name ?? ''
      if (name.length > 10 || /固体饮料|速溶/.test(name)) return [false, `名称太长：${name}`]
      if (!payload.product?.package) return [false, `名称 ${name}，但没带净含量`]
      return [true, name]
    },
  },
  {
    name: '归组：拿铁',
    source: '2026-11-11 拿铁记成两项单独的咖啡和牛奶，没有 groupName，卡片上看不出是一杯拿铁',
    build: () => ({
      instructions: instructions(['coffee', 'milk']),
      input: [state(), { role: 'user', content: '刚喝了杯拿铁，用了两克的冻干咖啡，加上170ml 的鲜牛奶吧' }],
      toolChoice: 'required',
    }),
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      if (!call) return [false, `没出卡：${text(body).slice(0, 50)}`]
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      const groups = [...new Set(items.map((i) => i.groupName ?? ''))]
      if (items.length < 2) return [false, `只有 ${items.length} 项`]
      return groups.length === 1 && groups[0].includes('拿铁') ? [true, groups[0]] : [false, `groupName：${JSON.stringify(groups)}`]
    },
  },
  {
    name: '归组：单独的几样不归组',
    source: '2026-11-11 加归组规则时的反例：防止把一顿里的几样硬编成一道菜',
    build: () => ({
      instructions: instructions(['milk', 'egg']),
      input: [state(), { role: 'user', content: '早上吃了一个水煮蛋，喝了 250ml 鲜牛奶' }],
      toolChoice: 'required',
    }),
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      if (!call) return [false, `没出卡：${text(body).slice(0, 50)}`]
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      const named = items.map((i) => i.groupName).filter(Boolean)
      if (items.some((i) => /油/.test(i.displayName ?? ''))) return [false, '水煮也加了油']
      return named.length === 0 ? [true] : [false, `乱加了 groupName：${named.join('、')}`]
    },
  },
  {
    name: '多样漏项：罗非鱼 + 小白菜 + 米饭',
    source: '2026-11-11 推理里说要记三样，提案只带了第一样（doubao-seed-2.1-lite）',
    build: () => {
      return {
        instructions: instructions(['milk', 'coffee']),
        input: [
          state({ date: '2026-11-11', revision: 1, records: ['  - 加餐［7a1e0000-0000-4000-8000-000000000021］：拿铁（摩可纳 8 号、小象鲜牛奶）'] }),
          { role: 'user', content: '刚吃了红烧罗非鱼，大概一斤重（净肉含量我不知道，你自己估算）。\n还有 300g 清炒小白菜，以及 100g 生重的大米饭。' },
          ...searchTurn('call_1', '罗非鱼', { referenceFoodId: 'vita.reference.tilapia.raw', name: '罗非鱼（生）', aliases: ['罗非鱼'], preparationState: 'raw', per100g: { energyKcal: 98, proteinG: 18.4, fatG: 1.5, carbohydrateG: 2.8 } }),
          ...searchTurn('call_2', '小白菜', { referenceFoodId: 'vita.reference.bok-choy.raw', name: '小白菜（生）', aliases: ['小白菜', '青菜'], preparationState: 'raw', per100g: { energyKcal: 14, proteinG: 1.4, fatG: 0.3, carbohydrateG: 2.4 } }),
          ...searchTurn('call_3', '大米', { referenceFoodId: 'vita.reference.rice.white.raw', name: '大米（生）', aliases: ['大米', '稻米', '白米', '生米'], preparationState: 'raw', per100g: { energyKcal: 346, proteinG: 7.9, fatG: 0.9, carbohydrateG: 77.2 } }),
        ],
      }
    },
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      // 先问估算口径、或再查一样（如烹调用油）都算合理，单独标出来；只说不做才算失败。
      if (!call) {
        const other = calls(body).map((c) => c.name)
        if (other.length) return [true, `还在查：${[...new Set(other)].join('、')}`]
        return /[？?]/.test(text(body)) ? [true, '先问了'] : [false, `没出卡：${text(body).slice(0, 50)}`]
      }
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      // 鱼按参考库还是按熟食估算都行，只看三样是否都在。
      const names = items.map((i) => i.displayName ?? '').join('、')
      const missing = [/鱼/, /白菜|青菜/, /米/].filter((re) => !re.test(names))
      return missing.length === 0 ? [true] : [false, `漏项：只有 ${names}`]
    },
  },
  {
    name: '烹调用油：清炒小白菜',
    source: '2026-11-11 红烧罗非鱼、清炒小白菜都没计油，热量少算约两三百千卡',
    build: () => {
      return {
        instructions: instructions(['milk']),
        input: [
          state({ date: '2026-11-11' }),
          { role: 'user', content: '中午吃了 300g 清炒小白菜，还有 100g 生重的大米饭' },
          ...searchTurn('call_1', '小白菜', { referenceFoodId: 'vita.reference.bok-choy.raw', name: '小白菜（生）', aliases: ['小白菜', '青菜'], preparationState: 'raw', per100g: { energyKcal: 14, proteinG: 1.4, fatG: 0.3, carbohydrateG: 2.4 } }),
          ...searchTurn('call_2', '大米', { referenceFoodId: 'vita.reference.rice.white.raw', name: '大米（生）', aliases: ['大米', '稻米', '白米', '生米'], preparationState: 'raw', per100g: { energyKcal: 346, proteinG: 7.9, fatG: 0.9, carbohydrateG: 77.2 } }),
        ],
      }
    },
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      if (!call) {
        const queries = calls(body).filter((c) => c.name === 'searchReferenceFoods').map((c) => c.args?.query ?? '')
        if (queries.some((q) => /油/.test(q))) return [true, '去查油了']
        return [false, queries.length ? `还在查：${queries.join('、')}` : `没出卡：${text(body).slice(0, 50)}`]
      }
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      const oil = items.find((i) => /油/.test(i.displayName ?? ''))
      const veg = items.find((i) => /白菜|青菜/.test(i.displayName ?? '') || /白菜/.test(i.groupName ?? ''))
      if (!oil) return [false, `没计油：${items.map((i) => i.displayName).join('、')}`]
      if (!veg || !oil.groupName || oil.groupName !== veg.groupName) return [false, `油没和小白菜归一组：${oil.groupName ?? '空'} / ${veg?.groupName ?? '空'}`]
      if (items.some((i) => /米/.test(i.displayName ?? '') && i.groupName === oil.groupName)) return [false, '米饭也被归进了菜里']
      return [true, `${oil.quantity?.amount ?? '?'} g 油`]
    },
  },
  {
    name: '补项并归组：红烧鱼补油',
    source: '2026-11-11 补记时只给新加的油分组，已记的鱼留在组外（“红烧罗非鱼”组里只有油）',
    build: () => ({
      instructions: instructions(['milk', 'coffee']),
      input: [
        state({
          date: '2026-11-11',
          revision: 2,
          records: ['  - 晚餐［36899d47-780a-4c48-9e42-ddafeb034ef9］：红烧罗非鱼［d097de45-272a-4455-bd9b-e5628c29d419］大概一斤重（净肉含量我自己估算）'],
        }),
        { role: 'user', content: '你漏记了，晚餐漏了 300g 清炒小白菜和 100g 生重的大米，红烧鱼和清炒小白菜的油也补上，归到各自的菜名下' },
        ...searchTurn('call_1', '小白菜', { referenceFoodId: 'vita.reference.bok-choy.raw', name: '小白菜（生）', aliases: ['小白菜', '青菜'], preparationState: 'raw', per100g: { energyKcal: 14, proteinG: 1.4, fatG: 0.3, carbohydrateG: 2.4 } }),
        ...searchTurn('call_2', '大米', { referenceFoodId: 'vita.reference.rice.white.raw', name: '大米（生）', aliases: ['大米', '稻米', '白米', '生米'], preparationState: 'raw', per100g: { energyKcal: 346, proteinG: 7.9, fatG: 0.9, carbohydrateG: 77.2 } }),
        ...OIL_SEARCH,
      ],
    }),
    check(body) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      if (!call) return [false, `没出卡：${text(body).slice(0, 50)}`]
      const payload = call.args.payload ?? {}
      if (payload.intent !== 'appendItems') return [false, `intent 是 ${payload.intent}`]
      const fish = (payload.regroup ?? []).find((r) => r.itemId === 'd097de45-272a-4455-bd9b-e5628c29d419')
      if (!fish) return [false, '没把已有的鱼改分组']
      const fishOil = (payload.items ?? []).find((i) => /油/.test(i.displayName ?? '') && i.groupName === fish.groupName)
      return fishOil ? [true, fish.groupName] : [false, `鱼改到了“${fish.groupName}”，但没有油在同一组`]
    },
  },
  {
    name: '历史里有假出卡：重发牛奶',
    source: '2026-11-04 模型照抄历史里的“已生成确认卡”，没调工具',
    build: () => {
      const message = userWithPhoto('存进营养库，这个小象的鲜牛奶，它是950ml，就是一大盒这样', 'milk', '3c330905-163b-4145-ab89-1cc378c24344')
      if (!message) return null
      return {
        instructions: instructions(['coffee']),
        input: [
          { role: 'user', content: '记录一下这个小象的鲜牛奶，它是 950ml，就是一大盒这样\n\n［客户端附件：之前发过 1 张营养标签照片（labelScanId: 75fd1abb-d936-40bb-9e52-90f8c37b8c9d），已处理过，图片不再附上。］' },
          { role: 'assistant', content: '已生成小象鲜牛奶的存库确认卡：每 100 ml 67.4 kcal、蛋白质 3.3 g、脂肪 3.9 g、碳水 4.8 g。\n\n（这次实际没有生成确认卡，没有保存任何数据。请再说一次，或换个说法。）' },
          state(),
          message,
        ],
      }
    },
    check(body) {
      const payload = foodProposal(body)
      if (!payload) return [false, `没出卡：${text(body).slice(0, 50)}`]
      const pack = payload.product?.package
      const sodium = payload.version?.values?.sodiumMg
      if (!pack || pack.amount !== 950) return [false, `净含量不对：${JSON.stringify(pack)}`]
      return sodium === 60 ? [true] : [false, `钠不对：${sodium}`]
    },
  },
]

// “已查到油”变体：历史里已有一次植物油查询，只看最后出的卡（v12 起模型会先去查油，第一次回应看不到卡）。
// 这时再“还在查”就算失败；罗非鱼那条还要求卡上有油。
const withOil = (base, name, needsOil) => ({
  ...base,
  name,
  build: () => {
    const built = base.build()
    return built && { ...built, input: [...built.input, ...OIL_SEARCH] }
  },
  check(body) {
    const [ok, note] = base.check(body)
    if (!ok || /还在查|去查油|先问了/.test(note ?? '')) return [false, note ?? '没出卡']
    if (needsOil) {
      const call = calls(body).find((c) => c.name === 'proposeRecordChange')
      const items = call.args.payload?.record?.items ?? call.args.payload?.items ?? []
      if (!items.some((i) => /油/.test(i.displayName ?? ''))) return [false, '没计油']
    }
    return [ok, note]
  },
})
CASES.push(
  withOil(CASES.find((c) => c.name.startsWith('多样漏项')), '多样漏项（已查到油）：罗非鱼 + 小白菜 + 米饭', true),
  withOil(CASES.find((c) => c.name.startsWith('烹调用油')), '烹调用油（已查到油）：清炒小白菜', false),
)

// MARK: - 运行

async function once(model, built) {
  const started = Date.now()
  const res = await fetch(`${BASE}/v1/responses`, {
    method: 'POST',
    headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      model,
      store: false,
      stream: false,
      instructions: built.instructions,
      input: built.input,
      tools,
      reasoning: { effort: EFFORT },
      ...(built.toolChoice ? { tool_choice: built.toolChoice } : {}),
    }),
  })
  const body = await res.json().catch(() => ({}))
  return { seconds: (Date.now() - started) / 1000, body, error: !res.ok || body.error ? (body.error?.message ?? `HTTP ${res.status}`) : null }
}

const selected = CASES.filter((c) => !args.case || c.name.includes(args.case))
console.log(`prompt v${config.prompts.system.version}，每个用例 ${RUNS} 次，effort ${EFFORT}\n`)
for (const model of MODELS) {
  console.log(`## ${model}`)
  for (const testCase of selected) {
    const built = testCase.build()
    if (!built) {
      console.log(`- ${testCase.name}：跳过（缺照片，先跑 fetch-fixtures.sh）`)
      continue
    }
    const results = []
    for (let i = 0; i < RUNS; i += CONCURRENCY) {
      results.push(...(await Promise.all(Array.from({ length: Math.min(CONCURRENCY, RUNS - i) }, () => once(model, built)))))
    }
    const verdicts = results.map((r) =>
      r.error ? [false, `出错：${r.error}`] : malformed(r.body) ? [false, '工具参数不是合法 JSON'] : testCase.check(r.body),
    )
    const passed = verdicts.filter(([ok]) => ok).length
    const seconds = (results.reduce((sum, r) => sum + r.seconds, 0) / results.length).toFixed(1)
    const notes = [...new Set(verdicts.map(([, note]) => note).filter(Boolean))].slice(0, 4).join('；')
    console.log(`- ${testCase.name}：${passed}/${RUNS}，平均 ${seconds} 秒${notes ? `（${notes}）` : ''}`)
    // --dump：打出失败那几次的响应概况，看模型到底返回了什么。
    if ('dump' in args) {
      results.forEach((r, i) => {
        if (verdicts[i][0]) return
        const b = r.body
        const reasoning = (b.output ?? []).filter((o) => o.type === 'reasoning').flatMap((o) => o.summary ?? o.content ?? []).map((c) => c.text ?? '').join('')
        console.log(`  · status=${b.status} incomplete=${JSON.stringify(b.incomplete_details ?? null)} output=[${(b.output ?? []).map((o) => o.type).join(',')}] tokens_out=${b.usage?.output_tokens}`)
        console.log(`    文字：${JSON.stringify(text(b).slice(0, 200))}`)
        console.log(`    推理结尾：${JSON.stringify(reasoning.slice(-300))}`)
      })
    }
  }
  console.log()
}
