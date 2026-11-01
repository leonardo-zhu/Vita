import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { listAudit } from '../audit'
import { resetDbForTests } from '../db'
import { draftFromBuiltin } from './model'
import {
  PublishError,
  currentRelease,
  discardDraft,
  getDraft,
  listReleases,
  publish,
  rollback,
  saveDraft,
} from './service'

const actor = { name: 'admin', ip: '127.0.0.1' }
let dir: string

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), 'vita-admin-'))
  process.env.VITA_ADMIN_DATA_DIR = dir
  delete process.env.VITA_PUBLISH_DIR
  resetDbForTests()
})

afterEach(() => resetDbForTests())

const publishedFile = () =>
  JSON.parse(readFileSync(path.join(dir, 'published', 'stable.json'), 'utf8'))

describe('config service', () => {
  it('starts from the built-in defaults with nothing published', () => {
    const draft = getDraft()
    expect(draft.content).toEqual(draftFromBuiltin())
    expect(draft.saved).toBe(false)
    expect(draft.dirty).toBe(true)
    expect(draft.current).toBeNull()
  })

  it('publishes the draft to the file, the release table and the audit log', () => {
    saveDraft({ ...draftFromBuiltin(), systemPrompt: '新的 prompt' }, actor)
    const release = publish('第一次发布', actor)

    expect(currentRelease()?.id).toBe(release.id)
    expect(publishedFile()).toEqual(release.content)
    expect(publishedFile().prompts.system.text).toBe('新的 prompt')
    expect(getDraft()).toMatchObject({ saved: false, dirty: false })
    expect(listAudit().map((row) => row.action)).toEqual(['publish', 'draft_save'])
  })

  it('refuses to publish an invalid draft and keeps the old file', () => {
    publish('', actor)
    const before = publishedFile()
    saveDraft({ ...draftFromBuiltin(), llm: { ...draftFromBuiltin().llm, maxRetries: 9 } }, actor)
    expect(() => publish('', actor)).toThrow(PublishError)
    expect(publishedFile()).toEqual(before)
    expect(listReleases()).toHaveLength(1)
  })

  it('discards the draft back to what is published', () => {
    publish('', actor)
    saveDraft({ ...draftFromBuiltin(), systemPrompt: '还没发' }, actor)
    expect(getDraft().dirty).toBe(true)
    discardDraft(actor)
    expect(getDraft()).toMatchObject({ dirty: false, saved: false })
  })

  it('rolls back by republishing old content under a newer version', () => {
    const first = publish('', actor)
    saveDraft({ ...draftFromBuiltin(), systemPrompt: '第二版' }, actor)
    const second = publish('', actor)
    const third = rollback(first.id, actor)

    expect(third.rollback_of).toBe(first.id)
    expect(third.config_version > second.config_version).toBe(true)
    expect(publishedFile().prompts.system).toBeUndefined()
    expect(publishedFile().configVersion).toBe(third.config_version)
    expect(getDraft().content.systemPrompt).toBe(draftFromBuiltin().systemPrompt)
  })

  it('rejects edits to the audit log', async () => {
    publish('', actor)
    const { db } = await import('../db')
    expect(() => db().exec('DELETE FROM admin_audit')).toThrow(/append-only/)
  })
})
