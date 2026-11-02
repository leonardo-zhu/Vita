import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import example from '@/generated/diagnostics-example-batch.json'

import { db, resetDbForTests } from '../db'
import { ingest, purgeExpired, resetRateLimitForTests, validate } from './ingest'
import { deleteInstall, recentEvents, setInstallRevoked, summary } from './query'

/** 示例批次的时间改到现在，免得被保留期过滤掉 */
function freshBatch() {
  const batch = structuredClone(example)
  batch.events.forEach((event, i) => {
    event.occurredAt = new Date(Date.now() - i * 60_000).toISOString()
  })
  return batch
}

beforeEach(() => {
  process.env.VITA_ADMIN_DATA_DIR = mkdtempSync(path.join(tmpdir(), 'vita-admin-'))
  resetDbForTests()
  resetRateLimitForTests()
})
afterEach(() => resetDbForTests())

describe('validate', () => {
  it('accepts the shared example batch', () => {
    expect(validate(example)).toBe(true)
  })

  it('rejects extra fields, free text and unknown event types', () => {
    const extra = structuredClone(example) as Record<string, unknown>
    ;(extra.events as Record<string, unknown>[])[0].message = '中午吃了鸡胸肉'
    expect(validate(extra)).toBe(false)

    const badCode = structuredClone(example)
    ;(badCode.events[2] as { errorCode: string }).errorCode = '请求没有被接受：model not found'
    expect(validate(badCode)).toBe(false)

    const unknownType = structuredClone(example)
    ;(unknownType.events[3] as { type: string }).type = 'screenshot'
    expect(validate(unknownType)).toBe(false)
  })
})

describe('ingest', () => {
  it('stores events once and reports duplicates on retry', () => {
    const batch = freshBatch()
    expect(ingest(batch, '1.2.3.4')).toEqual({ status: 200, accepted: 4, duplicates: 0, dropped: 0 })
    expect(ingest(batch, '1.2.3.4')).toEqual({ status: 200, accepted: 0, duplicates: 4, dropped: 0 })
  })

  it('drops events outside the retention window', () => {
    const batch = freshBatch()
    batch.events[0].occurredAt = '2020-01-01T00:00:00Z'
    expect(ingest(batch, '1.2.3.4')).toMatchObject({ status: 200, accepted: 3, dropped: 1 })
  })

  it('refuses revoked installs and rate-limits a busy client', () => {
    ingest(freshBatch(), '1.2.3.4')
    setInstallRevoked(example.installId, true)
    expect(ingest(freshBatch(), '1.2.3.4')).toEqual({ status: 403, error: 'install revoked' })

    resetRateLimitForTests()
    const results = Array.from({ length: 61 }, () => ingest({ bogus: true }, '5.6.7.8').status)
    expect(results.at(-1)).toBe(429)
  })

  it('summarizes chats, tools and config fetches', () => {
    ingest(freshBatch(), '1.2.3.4')
    const result = summary({ days: 7 })
    expect(result.chat).toMatchObject({ count: 2, errors: 1, p95: 18250, createdPending: 1 })
    // 示例里成功的那轮输入 5120、命中缓存 3072
    expect(result.chat.cacheRate).toBeCloseTo(0.6)
    expect(result.tools[0]).toMatchObject({ tool: 'proposeRecordChange', count: 1, failures: 0 })
    expect(result.configFetch).toEqual({ updated: 1, unchanged: 0, failed: 0 })
    expect(result.errorCodes).toEqual([{ code: 'llm.timeout', type: 'chat_turn', count: 1 }])
    expect(result.byConfigVersion[0]).toMatchObject({ configVersion: '2026-11-02.1', count: 2 })
  })

  it('returns recent events as plain objects a client component can take', () => {
    ingest(freshBatch(), '1.2.3.4')
    const events = recentEvents({ days: 7 })
    expect(events).toHaveLength(4)
    expect(events.every((event) => Object.getPrototypeOf(event) === Object.prototype)).toBe(true)
  })

  it('deletes everything for one install and purges old rows', () => {
    ingest(freshBatch(), '1.2.3.4')
    expect(deleteInstall(example.installId, false)).toBe(4)
    expect(summary({ days: 7 }).chat.count).toBe(0)

    ingest(freshBatch(), '1.2.3.4')
    db().exec('UPDATE diagnostic_events SET occurred_at = occurred_at - 40 * 86400')
    purgeExpired()
    expect(summary({ days: 365 }).chat.count).toBe(0)
  })
})
