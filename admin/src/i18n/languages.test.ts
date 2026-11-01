import { describe, expect, it } from 'vitest'

import { langFromAcceptLanguage } from './languages'

describe('langFromAcceptLanguage', () => {
  it('maps any Chinese variant to zh and falls back to en', () => {
    expect(langFromAcceptLanguage('zh-CN,zh;q=0.9,en;q=0.8')).toBe('zh')
    expect(langFromAcceptLanguage('zh-TW')).toBe('zh')
    expect(langFromAcceptLanguage('en-GB,en;q=0.9')).toBe('en')
    expect(langFromAcceptLanguage('fr-FR,de;q=0.8')).toBe('en')
    expect(langFromAcceptLanguage('fr-FR,zh;q=0.5')).toBe('zh')
    expect(langFromAcceptLanguage(null)).toBe('en')
  })
})
