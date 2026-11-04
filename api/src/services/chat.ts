/**
 * 对话历史、标签照片与对话追踪的存取（替代 1.0 的 ChatHistoryService 与 LabelScanService）。
 */
import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'

import type { CardRef, ChatMessage, ChatTrace } from '@vita/contract'

import { audit } from '../db.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'

interface MessageRow {
  id: string
  role: ChatMessage['role']
  text: string
  card_ref: string | null
  label_scan_ids: string | null
  excluded_at: string | null
  created_at: string
}

function parseCardRef(raw: string | null): CardRef | null {
  if (!raw) return null
  const [type, id] = raw.split(':')
  return (type === 'pending' || type === 'label') && id ? { type, id } : null
}

export class ChatService {
  private readonly context: ServiceContext

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 某天的全部消息，按时间顺序。 */
  messages(date: string): ChatMessage[] {
    const rows = this.context.database
      .prepare('SELECT id, role, text, card_ref, label_scan_ids, excluded_at, created_at FROM chat_messages WHERE session_date = ? ORDER BY created_at, rowid')
      .all(date) as unknown as MessageRow[]
    return rows.map((row) => {
      const cardRef = parseCardRef(row.card_ref)
      // 只带一张照片的旧消息（含 1.0 导入的）没有 label_scan_ids，从 card_ref 推出来。
      const labelScanIds = row.label_scan_ids ? (JSON.parse(row.label_scan_ids) as string[]) : cardRef?.type === 'label' ? [cardRef.id] : []
      return { id: row.id, role: row.role, text: row.text, cardRef, labelScanIds, excludedFromContext: row.excluded_at !== null, createdAt: row.created_at }
    })
  }

  /** 用户消息带照片时传 labelScanIds，cardRef 自动指向第一张。 */
  append(date: string, role: ChatMessage['role'], text: string, cardRef: CardRef | null, labelScanIds: string[] = []): ChatMessage {
    const id = randomUUID()
    const createdAt = this.context.now().toISOString()
    const ref = cardRef ?? (labelScanIds.length ? { type: 'label' as const, id: labelScanIds[0] } : null)
    this.context.database
      .prepare('INSERT INTO chat_messages (id, session_date, role, text, card_ref, label_scan_ids, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .run(id, date, role, text, ref ? `${ref.type}:${ref.id}` : null, labelScanIds.length ? JSON.stringify(labelScanIds) : null, createdAt)
    return { id, role, text, cardRef: ref, labelScanIds, excludedFromContext: false, createdAt }
  }

  /** Admin 的 rewind：消息不再发给模型（或恢复）。返回更新后的消息；没有这条时抛 notFound。 */
  setExcluded(id: string, excluded: boolean, origin: WriteOrigin): ChatMessage {
    const { database } = this.context
    const row = database.prepare('SELECT session_date FROM chat_messages WHERE id = ?').get(id) as { session_date: string } | undefined
    if (!row) throw new ServiceError('chat', 'messageNotFound')
    const at = this.context.now()
    database.prepare('UPDATE chat_messages SET excluded_at = ? WHERE id = ?').run(excluded ? at.toISOString() : null, id)
    audit(database, { actor: origin.actor, action: excluded ? 'message.exclude' : 'message.include', targetId: id, result: 'success', at })
    return this.messages(row.session_date).find((message) => message.id === id)!
  }

  /** 这一天的对话追踪，按时间顺序。 */
  traces(date: string): ChatTrace[] {
    const rows = this.context.database
      .prepare('SELECT * FROM chat_traces WHERE session_date = ? ORDER BY created_at')
      .all(date) as Record<string, unknown>[]
    return rows.map((row) => ({
      requestId: row.request_id as string,
      sessionDate: row.session_date as string,
      kind: row.kind as ChatTrace['kind'],
      model: row.model as string,
      configVersion: row.config_version as string,
      inputText: row.input_text as string,
      labelScanIds: row.label_scan_ids ? (JSON.parse(row.label_scan_ids as string) as string[]) : row.label_scan_id ? [row.label_scan_id as string] : [],
      reply: (row.reply as string | null) ?? null,
      reasoning: (row.reasoning as string | null) ?? null,
      steps: JSON.parse(row.steps as string) as ChatTrace['steps'],
      pendingId: (row.pending_id as string | null) ?? null,
      outcome: row.outcome as ChatTrace['outcome'],
      errorCode: (row.error_code as string | null) ?? null,
      rounds: Number(row.rounds),
      tokensIn: row.tokens_in === null ? null : Number(row.tokens_in),
      tokensOut: row.tokens_out === null ? null : Number(row.tokens_out),
      tokensCached: row.tokens_cached === null ? null : Number(row.tokens_cached),
      hitMaxRounds: Boolean(row.hit_max_rounds),
      latencyMs: Number(row.latency_ms),
      createdAt: row.created_at as string,
    }))
  }

  /** 有对话的日期，新的在前。 */
  days(): { date: string; messages: number; excluded: number; lastAt: string }[] {
    return this.context.database
      .prepare(
        `SELECT session_date AS date, COUNT(*) AS messages, COUNT(excluded_at) AS excluded, MAX(created_at) AS lastAt
         FROM chat_messages GROUP BY session_date ORDER BY session_date DESC`,
      )
      .all()
      .map((row) => ({ date: String(row.date), messages: Number(row.messages), excluded: Number(row.excluded), lastAt: String(row.lastAt) }))
  }
}

/** 一张照片的上限。手机压到长边 2000 像素后通常只有几百 KB。 */
export const MAX_LABEL_BYTES = 8 * 1024 * 1024

/**
 * 营养标签照片（ADR-016）：手机压缩后上传，作为食品版本的来源依据存档，同时随消息发给模型读。
 * 文件在 VITA_API_FILES_DIR（默认数据目录下的 files/），库里只记引用。
 */
export class LabelService {
  private readonly context: ServiceContext
  private readonly directory: string

  constructor(context: ServiceContext, directory: string) {
    this.context = context
    this.directory = directory
  }

  save(bytes: Uint8Array, contentType: string, origin: WriteOrigin): string {
    if (contentType !== 'image/jpeg' && contentType !== 'image/png' && contentType !== 'image/heic') {
      throw new ServiceError('label', 'unsupportedImage')
    }
    if (bytes.length === 0 || bytes.length > MAX_LABEL_BYTES) throw new ServiceError('label', 'imageTooLarge')
    const id = randomUUID()
    const file = `label-${id}.${contentType.split('/')[1]}`
    mkdirSync(this.directory, { recursive: true })
    writeFileSync(path.join(this.directory, file), bytes)
    const at = this.context.now()
    this.context.database
      .prepare('INSERT INTO label_scans (id, created_at, file, content_type) VALUES (?, ?, ?, ?)')
      .run(id, at.toISOString(), file, contentType)
    audit(this.context.database, { actor: origin.actor, action: 'label.upload', targetId: id, result: 'success', at })
    return id
  }

  /** 读不到（不存在或文件丢了）时为 null。 */
  read(id: string): { bytes: Buffer; contentType: string } | null {
    const row = this.context.database.prepare('SELECT file, content_type FROM label_scans WHERE id = ?').get(id) as
      | { file: string | null; content_type: string | null }
      | undefined
    if (!row?.file || !row.content_type) return null
    try {
      return { bytes: readFileSync(path.join(this.directory, row.file)), contentType: row.content_type }
    } catch {
      return null
    }
  }

  exists(id: string): boolean {
    return this.context.database.prepare('SELECT 1 FROM label_scans WHERE id = ?').get(id) !== undefined
  }
}
