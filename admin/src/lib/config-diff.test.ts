import { describe, expect, it } from 'vitest'

import { draftFromBuiltin, knownTools } from '@/server/config/model'

import { configDiff, describeChanges } from './config-diff'

describe('configDiff', () => {
  it('lists value changes and full texts for changed prompts', () => {
    const before = draftFromBuiltin()
    const tool = knownTools()[0]
    const after = {
      ...before,
      llm: { ...before.llm, timeoutSeconds: 90, streaming: false },
      systemPrompt: before.systemPrompt + '\n新规则',
      toolDescriptions: { ...before.toolDescriptions, [tool]: '新描述' },
    }
    const entries = configDiff(before, after)
    expect(entries.map((entry) => entry.key)).toEqual([
      'llm.timeoutSeconds',
      'llm.streaming',
      'systemPrompt',
      `tool:${tool}`,
    ])
    expect(entries[2]).toMatchObject({ kind: 'text', from: before.systemPrompt, to: after.systemPrompt })
    expect(describeChanges(before, after)).toEqual([
      '超时秒数：60 → 90',
      '流式输出：开 → 关',
      '系统 prompt',
      `工具描述：${tool}`,
    ])
  })

  it('is empty for identical drafts', () => {
    expect(configDiff(draftFromBuiltin(), draftFromBuiltin())).toEqual([])
  })
})
