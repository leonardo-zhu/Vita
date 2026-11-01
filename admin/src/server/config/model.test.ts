import { describe, expect, it } from 'vitest'

import {
  buildPublished,
  builtin,
  draftFromBuiltin,
  draftFromPublished,
  knownTools,
  promptVersionHistory,
} from './model'
import { messages } from '@/i18n/messages'
import { issueText } from '@/lib/issue-text'

import { validatePublished } from './validate'

const tool = knownTools()[0]

describe('buildPublished', () => {
  it('leaves prompts that match the built-in defaults out of the file', () => {
    const config = buildPublished(draftFromBuiltin(), {
      configVersion: '2026-11-01.1',
      previous: null,
      history: {},
    })
    expect(config.prompts.system).toBeUndefined()
    expect(config.prompts.tools).toEqual({})
    expect(config.llm).toEqual(builtin.llm)
    expect(validatePublished(config, { latestVersion: null })).toEqual([])
  })

  it('bumps a changed prompt past both the built-in and historical versions', () => {
    const draft = { ...draftFromBuiltin(), systemPrompt: '新的系统 prompt' }
    draft.toolDescriptions = { ...draft.toolDescriptions, [tool]: '新的描述' }
    const config = buildPublished(draft, {
      configVersion: '2026-11-01.1',
      previous: null,
      history: { system: 7 },
    })
    expect(config.prompts.system).toEqual({
      id: builtin.prompts.system.id,
      version: 8,
      text: '新的系统 prompt',
    })
    expect(config.prompts.tools[tool]).toEqual({
      version: builtin.prompts.tools[tool].version + 1,
      description: '新的描述',
    })
  })

  it('keeps the version when the text did not change since the last release', () => {
    const draft = { ...draftFromBuiltin(), systemPrompt: '改过一次' }
    const first = buildPublished(draft, { configVersion: '2026-11-01.1', previous: null, history: {} })
    const second = buildPublished(draft, {
      configVersion: '2026-11-01.2',
      previous: first,
      history: promptVersionHistory([first]),
    })
    expect(second.prompts.system?.version).toBe(first.prompts.system?.version)
  })

  it('round-trips through the draft form', () => {
    const draft = { ...draftFromBuiltin(), systemPrompt: '改过', minClientVersion: '0.2.0' }
    const config = buildPublished(draft, { configVersion: '2026-11-01.1', previous: null, history: {} })
    expect(config.minClientVersion).toBe('0.2.0')
    expect(draftFromPublished(config)).toEqual(draft)
  })
})

describe('validatePublished', () => {
  const valid = () =>
    buildPublished(draftFromBuiltin(), { configVersion: '2026-11-01.1', previous: null, history: {} })

  it('reports out-of-range values with field labels', () => {
    const config = valid()
    config.llm.timeoutSeconds = 1
    config.llm.modelId = ''
    const issues = validatePublished(config, { latestVersion: null })
    expect(issues).toContainEqual({ path: '/llm/timeoutSeconds', rule: 'minimum', param: 5 })
    const zh = issues.map((issue) => issueText(messages.zh, issue))
    expect(zh).toContain('超时秒数不能小于 5')
    expect(zh).toContain('模型别名不能为空')
    expect(issues.map((issue) => issueText(messages.en, issue))).toContain('Timeout must be at least 5')
  })

  it('rejects unknown tools and non-increasing versions', () => {
    const config = valid()
    config.prompts.tools.deleteEverything = { version: 1, description: 'x' }
    const issues = validatePublished(config, { latestVersion: '2026-11-01.1' })
    expect(issues.map((issue) => issue.path)).toEqual(
      expect.arrayContaining(['/prompts/tools/deleteEverything', '/configVersion'])
    )
  })
})
