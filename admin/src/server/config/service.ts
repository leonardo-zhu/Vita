/**
 * 草稿、发布、回滚（vita-admin.md §8.3 / §11.2）。首期只有 stable 渠道。
 *
 * 发布在一个事务里完成：写 release、移动渠道指针、写审计、写发布文件。
 * 写文件失败时事务回滚，数据库和对外文件保持一致。
 */
import { createHash } from 'node:crypto'

import { recordAudit } from '../audit'
import { db, nowSeconds, transaction } from '../db'
import {
  CHANNEL,
  buildPublished,
  builtin,
  draftFromBuiltin,
  draftFromPublished,
  draftSchema,
  promptVersionHistory,
  sameDraft,
  type DraftContent,
  type PublishedConfig,
} from './model'
import { publishFile } from './publisher'
import { validatePublished, type ValidationIssue } from './validate'
import { compareConfigVersion, nextConfigVersion, todayInShanghai } from './version'

export interface ReleaseRow {
  id: number
  channel: string
  config_version: string
  content: string
  content_hash: string
  published_by: string
  published_at: number
  rollback_of: number | null
  note: string
}

export interface Release extends Omit<ReleaseRow, 'content'> {
  content: PublishedConfig
}

interface DraftRow {
  channel: string
  content: string
  base_release_id: number | null
  updated_by: string
  updated_at: number
}

function toRelease(row: ReleaseRow): Release {
  return { ...row, content: JSON.parse(row.content) as PublishedConfig }
}

export function listReleases(): Release[] {
  return (
    db()
      .prepare('SELECT * FROM config_releases WHERE channel = ? ORDER BY id DESC')
      .all(CHANNEL) as unknown as ReleaseRow[]
  ).map(toRelease)
}

export function getRelease(id: number): Release | null {
  const row = db()
    .prepare('SELECT * FROM config_releases WHERE id = ? AND channel = ?')
    .get(id, CHANNEL) as unknown as ReleaseRow | undefined
  return row ? toRelease(row) : null
}

export function currentRelease(): Release | null {
  const row = db()
    .prepare(
      `SELECT r.* FROM channels c JOIN config_releases r ON r.id = c.current_release_id
       WHERE c.name = ?`
    )
    .get(CHANNEL) as unknown as ReleaseRow | undefined
  return row ? toRelease(row) : null
}

export interface DraftState {
  content: DraftContent
  /** 草稿还没存过（直接取自当前发布或内置默认值） */
  saved: boolean
  updatedAt: number | null
  /** 与当前对外发布的内容不同 */
  dirty: boolean
  current: Release | null
}

export function getDraft(): DraftState {
  const current = currentRelease()
  const published = current ? draftFromPublished(current.content) : draftFromBuiltin()
  const row = db().prepare('SELECT * FROM config_drafts WHERE channel = ?').get(CHANNEL) as unknown as
    | DraftRow
    | undefined
  const parsed = row ? draftSchema.safeParse(JSON.parse(row.content)) : null
  // 内置默认值新增了工具或开关时，旧草稿里没有，补上内置值
  const content = parsed?.success ? withBuiltinKeys(parsed.data) : published
  return {
    content,
    saved: Boolean(parsed?.success),
    updatedAt: row?.updated_at ?? null,
    dirty: current ? !sameDraft(content, published) : true,
    current,
  }
}

function withBuiltinKeys(draft: DraftContent): DraftContent {
  const base = draftFromBuiltin()
  return {
    ...draft,
    toolDescriptions: { ...base.toolDescriptions, ...draft.toolDescriptions },
    features: { ...base.features, ...draft.features },
  }
}

export interface Actor {
  name: string
  ip: string
}

export function saveDraft(input: unknown, actor: Actor): DraftContent {
  const content = draftSchema.parse(input)
  const before = getDraft().content
  transaction(() => {
    db()
      .prepare(
        `INSERT INTO config_drafts (channel, content, base_release_id, updated_by, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (channel) DO UPDATE SET content = excluded.content,
           base_release_id = excluded.base_release_id, updated_by = excluded.updated_by,
           updated_at = excluded.updated_at`
      )
      .run(CHANNEL, JSON.stringify(content), currentRelease()?.id ?? null, actor.name, nowSeconds())
    recordAudit({
      actor: actor.name,
      action: 'draft_save',
      targetType: 'draft',
      targetId: CHANNEL,
      diff: draftDiff(before, content),
      ip: actor.ip,
    })
  })
  return content
}

/** 放弃草稿里的修改，回到当前对外发布的内容 */
export function discardDraft(actor: Actor) {
  transaction(() => {
    db().prepare('DELETE FROM config_drafts WHERE channel = ?').run(CHANNEL)
    recordAudit({ actor: actor.name, action: 'draft_reset', targetType: 'draft', targetId: CHANNEL, ip: actor.ip })
  })
}

/** 审计里记哪些字段变了；prompt 只记前后长度，全文在 release 里 */
function draftDiff(before: DraftContent, after: DraftContent) {
  const changes: Record<string, unknown> = {}
  const scalar = (key: string, a: unknown, b: unknown) => {
    if (JSON.stringify(a) !== JSON.stringify(b)) changes[key] = { from: a, to: b }
  }
  scalar('minClientVersion', before.minClientVersion, after.minClientVersion)
  for (const key of Object.keys(after.llm) as (keyof DraftContent['llm'])[]) {
    scalar(`llm.${key}`, before.llm[key], after.llm[key])
  }
  for (const key of Object.keys(after.context) as (keyof DraftContent['context'])[]) {
    scalar(`context.${key}`, before.context[key], after.context[key])
  }
  if (before.systemPrompt !== after.systemPrompt) {
    changes.systemPrompt = { fromLength: before.systemPrompt.length, toLength: after.systemPrompt.length }
  }
  for (const [name, text] of Object.entries(after.toolDescriptions)) {
    const old = before.toolDescriptions[name] ?? ''
    if (old !== text) changes[`tools.${name}`] = { fromLength: old.length, toLength: text.length }
  }
  for (const [name, enabled] of Object.entries(after.features)) {
    scalar(`features.${name}`, before.features[name], enabled)
  }
  return changes
}

/** 下一次发布会生成的文件，以及它过不过校验。发布页的预览与发布共用 */
export function preparePublish(draft: DraftContent = getDraft().content): {
  config: PublishedConfig
  issues: ValidationIssue[]
} {
  const releases = listReleases()
  const latest = releases[0]?.config_version ?? null
  const floor =
    latest && compareConfigVersion(latest, builtin.configVersion) > 0 ? latest : builtin.configVersion
  const config = buildPublished(draft, {
    configVersion: nextConfigVersion(floor, todayInShanghai()),
    previous: currentRelease()?.content ?? null,
    history: promptVersionHistory(releases.map((release) => release.content)),
  })
  return { config, issues: validatePublished(config, { latestVersion: latest }) }
}

export class PublishError extends Error {
  constructor(
    message: string,
    readonly issues: ValidationIssue[] = []
  ) {
    super(message)
  }
}

function insertRelease(
  config: PublishedConfig,
  actor: Actor,
  note: string,
  rollbackOf: number | null
): number {
  const body = `${JSON.stringify(config, null, 2)}\n`
  const hash = createHash('sha256').update(body).digest('hex')
  const result = db()
    .prepare(
      `INSERT INTO config_releases
         (channel, config_version, content, content_hash, published_by, published_at, rollback_of, note)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(CHANNEL, config.configVersion, body, hash, actor.name, nowSeconds(), rollbackOf, note)
  const id = Number(result.lastInsertRowid)
  db().prepare('UPDATE channels SET current_release_id = ? WHERE name = ?').run(id, CHANNEL)
  // 发布后草稿就是对外的内容，删掉草稿行即可
  db().prepare('DELETE FROM config_drafts WHERE channel = ?').run(CHANNEL)
  publishFile(CHANNEL, body)
  return id
}

export function publish(note: string, actor: Actor): Release {
  const { config, issues } = preparePublish()
  if (issues.length) throw new PublishError('配置没有通过校验', issues)
  const previous = currentRelease()
  const id = transaction(() => {
    const id = insertRelease(config, actor, note.trim(), null)
    recordAudit({
      actor: actor.name,
      action: 'publish',
      targetType: 'release',
      targetId: config.configVersion,
      diff: previous ? draftDiff(draftFromPublished(previous.content), draftFromPublished(config)) : null,
      ip: actor.ip,
    })
    return id
  })
  return getRelease(id)!
}

/** 回滚：以新的版本号重新发布旧版本的内容（vita-admin.md §5），客户端不支持降版本 */
export function rollback(releaseId: number, actor: Actor): Release {
  const target = getRelease(releaseId)
  if (!target) throw new PublishError('找不到这个版本')
  const releases = listReleases()
  const latest = releases[0]?.config_version ?? null
  const floor =
    latest && compareConfigVersion(latest, builtin.configVersion) > 0 ? latest : builtin.configVersion
  const config: PublishedConfig = {
    ...target.content,
    configVersion: nextConfigVersion(floor, todayInShanghai()),
  }
  const issues = validatePublished(config, { latestVersion: latest })
  if (issues.length) throw new PublishError('这个版本的内容没有通过当前的校验', issues)
  const id = transaction(() => {
    const id = insertRelease(config, actor, `回滚到 ${target.config_version}`, target.id)
    recordAudit({
      actor: actor.name,
      action: 'rollback',
      targetType: 'release',
      targetId: config.configVersion,
      diff: { rollbackOf: target.config_version },
      ip: actor.ip,
    })
    return id
  })
  return getRelease(id)!
}
