/** Admin 变更审计（vita-admin.md §11.3）：谁在何时做了什么。表只追加，触发器禁止改删。 */
import 'server-only'

import { db, nowSeconds } from './db'

export type AuditAction =
  | 'login'
  | 'login_failed'
  | 'logout'
  | 'passkey_add'
  | 'passkey_remove'
  | 'draft_save'
  | 'draft_reset'
  | 'publish'
  | 'rollback'

export interface AuditEntry {
  actor: string
  action: AuditAction
  targetType?: string
  targetId?: string
  diff?: unknown
  ip?: string
}

export interface AuditRow {
  id: number
  actor: string
  action: AuditAction
  target_type: string
  target_id: string
  diff: string | null
  ip: string
  at: number
}

export function recordAudit(entry: AuditEntry) {
  db()
    .prepare(
      `INSERT INTO admin_audit (actor, action, target_type, target_id, diff, ip, at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      entry.actor,
      entry.action,
      entry.targetType ?? '',
      entry.targetId ?? '',
      entry.diff === undefined ? null : JSON.stringify(entry.diff),
      entry.ip ?? '',
      nowSeconds()
    )
}

export function listAudit(limit = 200): AuditRow[] {
  return db()
    .prepare('SELECT * FROM admin_audit ORDER BY id DESC LIMIT ?')
    .all(limit) as unknown as AuditRow[]
}
