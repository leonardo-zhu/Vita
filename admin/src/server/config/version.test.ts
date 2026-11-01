import { describe, expect, it } from 'vitest'

import { compareConfigVersion, nextConfigVersion, todayInShanghai } from './version'

describe('configVersion', () => {
  it('compares the sequence number numerically', () => {
    expect(compareConfigVersion('2026-11-01.10', '2026-11-01.9')).toBeGreaterThan(0)
    expect(compareConfigVersion('2026-10-31.9', '2026-11-01.1')).toBeLessThan(0)
    expect(compareConfigVersion('2026-11-01.2', '2026-11-01.2')).toBe(0)
  })

  it('starts a new day at .1 and bumps within the same day', () => {
    expect(nextConfigVersion(null, '2026-11-01')).toBe('2026-11-01.1')
    expect(nextConfigVersion('2026-10-31.4', '2026-11-01')).toBe('2026-11-01.1')
    expect(nextConfigVersion('2026-11-01.9', '2026-11-01')).toBe('2026-11-01.10')
  })

  it('stays monotonic when the clock is behind the latest release', () => {
    expect(nextConfigVersion('2026-11-02.3', '2026-11-01')).toBe('2026-11-02.4')
  })

  it('uses the Shanghai calendar day', () => {
    expect(todayInShanghai(new Date('2026-10-31T16:30:00Z'))).toBe('2026-11-01')
  })
})
