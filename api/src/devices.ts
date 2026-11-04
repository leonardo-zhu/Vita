/**
 * 设备令牌（《Vita 2.0 架构设计》§8）：Admin 签发，手机存进 Keychain，每个请求带上。
 * 令牌是 `vita_` + 32 字节随机数（base64url），库里只存 sha256；吊销后立即失效。
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import type { DatabaseSync } from 'node:sqlite'

import type { Device } from '@vita/contract'

interface DeviceRow {
  id: string
  name: string
  created_at: string
  last_used_at: string | null
  revoked_at: string | null
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex')
}

function toDevice(row: DeviceRow): Device {
  return { id: row.id, name: row.name, createdAt: row.created_at, lastUsedAt: row.last_used_at, revokedAt: row.revoked_at }
}

const COLUMNS = 'id, name, created_at, last_used_at, revoked_at'

export function createDevice(database: DatabaseSync, name: string, now: Date): { device: Device; token: string } {
  const token = 'vita_' + randomBytes(32).toString('base64url')
  const id = randomUUID()
  database
    .prepare('INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)')
    .run(id, name, hashToken(token), now.toISOString())
  return { device: getDevice(database, id)!, token }
}

export function getDevice(database: DatabaseSync, id: string): Device | null {
  const row = database.prepare(`SELECT ${COLUMNS} FROM devices WHERE id = ?`).get(id) as DeviceRow | undefined
  return row ? toDevice(row) : null
}

export function listDevices(database: DatabaseSync): Device[] {
  return (database.prepare(`SELECT ${COLUMNS} FROM devices ORDER BY created_at DESC`).all() as unknown as DeviceRow[]).map(toDevice)
}

/** 已吊销返回 false；不存在返回 null。 */
export function revokeDevice(database: DatabaseSync, id: string, now: Date): boolean | null {
  const device = getDevice(database, id)
  if (!device) return null
  if (device.revokedAt) return false
  database.prepare('UPDATE devices SET revoked_at = ? WHERE id = ?').run(now.toISOString(), id)
  return true
}

/** 按令牌找到未吊销的设备，并记下最后使用时间。 */
export function authenticateDevice(database: DatabaseSync, token: string, now: Date): Device | null {
  const row = database
    .prepare(`SELECT ${COLUMNS} FROM devices WHERE token_hash = ? AND revoked_at IS NULL`)
    .get(hashToken(token)) as DeviceRow | undefined
  if (!row) return null
  database.prepare('UPDATE devices SET last_used_at = ? WHERE id = ?').run(now.toISOString(), row.id)
  return toDevice({ ...row, last_used_at: now.toISOString() })
}
