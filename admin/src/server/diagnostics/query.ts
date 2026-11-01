/**
 * 诊断日志的查询与聚合（vita-admin.md §11.4）：按时间、配置版本、App 版本、错误码筛选；
 * 错误率与 P50 / P95 耗时；按配置版本对比，看一次发布前后的效果。
 */
import 'server-only'

import { db, nowSeconds } from '../db'

export interface DiagnosticsFilter {
  days: number
  configVersion?: string
  appVersion?: string
  errorCode?: string
}

function where(filter: DiagnosticsFilter, type?: string) {
  const clauses = ['occurred_at >= ?']
  const params: (string | number)[] = [nowSeconds() - filter.days * 86400]
  if (type) {
    clauses.push('event_type = ?')
    params.push(type)
  }
  if (filter.configVersion) {
    clauses.push('config_version = ?')
    params.push(filter.configVersion)
  }
  if (filter.appVersion) {
    clauses.push('app_version = ?')
    params.push(filter.appVersion)
  }
  if (filter.errorCode) {
    clauses.push('(error_code = ? OR result_code = ?)')
    params.push(filter.errorCode, filter.errorCode)
  }
  return { sql: clauses.join(' AND '), params }
}

export function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)
  return sorted[Math.max(0, index)]
}

interface Latencies {
  count: number
  p50: number | null
  p95: number | null
}

function latencyStats(values: number[]): Latencies {
  const sorted = [...values].sort((a, b) => a - b)
  return { count: sorted.length, p50: percentile(sorted, 50), p95: percentile(sorted, 95) }
}

export interface ChatSummary extends Latencies {
  errors: number
  cancelled: number
  avgTokensIn: number | null
  avgTokensOut: number | null
  createdPending: number
  claimedCardWithoutTool: number
  hitMaxRounds: number
}

interface ChatRow {
  outcome: string
  latency_ms: number
  tokens_in: number | null
  tokens_out: number | null
  created_pending: number | null
  claimed_card_without_tool: number | null
  hit_max_rounds: number | null
  config_version: string | null
}

function summarizeChats(rows: ChatRow[]): ChatSummary {
  const ok = rows.filter((row) => row.outcome === 'ok')
  const avg = (values: (number | null)[]) => {
    const present = values.filter((v): v is number => v !== null)
    return present.length ? Math.round(present.reduce((a, b) => a + b, 0) / present.length) : null
  }
  return {
    ...latencyStats(ok.map((row) => row.latency_ms)),
    count: rows.length,
    errors: rows.filter((row) => row.outcome === 'error').length,
    cancelled: rows.filter((row) => row.outcome === 'cancelled').length,
    avgTokensIn: avg(ok.map((row) => row.tokens_in)),
    avgTokensOut: avg(ok.map((row) => row.tokens_out)),
    createdPending: rows.filter((row) => row.created_pending === 1).length,
    claimedCardWithoutTool: rows.filter((row) => row.claimed_card_without_tool === 1).length,
    hitMaxRounds: rows.filter((row) => row.hit_max_rounds === 1).length,
  }
}

export interface ToolSummary extends Latencies {
  tool: string
  failures: number
  codes: Record<string, number>
}

export interface DiagnosticsSummary {
  chat: ChatSummary
  byConfigVersion: (ChatSummary & { configVersion: string })[]
  errorCodes: { code: string; type: string; count: number }[]
  tools: ToolSummary[]
  configFetch: { updated: number; unchanged: number; failed: number }
  installs: number
}

export function summary(filter: DiagnosticsFilter): DiagnosticsSummary {
  const chatWhere = where(filter, 'chat_turn')
  const chats = db()
    .prepare(
      `SELECT outcome, latency_ms, tokens_in, tokens_out, created_pending, claimed_card_without_tool,
              hit_max_rounds, config_version FROM diagnostic_events WHERE ${chatWhere.sql}`
    )
    .all(...chatWhere.params) as unknown as ChatRow[]

  const versions = new Map<string, ChatRow[]>()
  for (const row of chats) {
    const key = row.config_version ?? '（内置）'
    versions.set(key, [...(versions.get(key) ?? []), row])
  }

  const all = where(filter)
  const errorCodes = db()
    .prepare(
      `SELECT COALESCE(error_code, result_code) AS code, event_type AS type, COUNT(*) AS count
       FROM diagnostic_events
       WHERE ${all.sql} AND (error_code IS NOT NULL OR (result_code IS NOT NULL AND result_code != 'ok'))
       GROUP BY code, type ORDER BY count DESC LIMIT 30`
    )
    .all(...all.params) as unknown as { code: string; type: string; count: number }[]

  const toolWhere = where(filter, 'tool_call')
  const toolRows = db()
    .prepare(`SELECT tool, result_code, latency_ms FROM diagnostic_events WHERE ${toolWhere.sql}`)
    .all(...toolWhere.params) as unknown as { tool: string; result_code: string; latency_ms: number }[]
  const byTool = new Map<string, typeof toolRows>()
  for (const row of toolRows) byTool.set(row.tool, [...(byTool.get(row.tool) ?? []), row])
  const tools = [...byTool.entries()]
    .map(([tool, rows]) => {
      const codes: Record<string, number> = {}
      for (const row of rows) codes[row.result_code] = (codes[row.result_code] ?? 0) + 1
      return {
        tool,
        ...latencyStats(rows.map((row) => row.latency_ms)),
        failures: rows.filter((row) => row.result_code !== 'ok').length,
        codes,
      }
    })
    .sort((a, b) => b.count - a.count)

  const fetchWhere = where(filter, 'config_fetch')
  const fetchRows = db()
    .prepare(`SELECT outcome, COUNT(*) AS count FROM diagnostic_events WHERE ${fetchWhere.sql} GROUP BY outcome`)
    .all(...fetchWhere.params) as unknown as { outcome: string; count: number }[]
  const configFetch = { updated: 0, unchanged: 0, failed: 0 }
  for (const row of fetchRows) {
    if (row.outcome in configFetch) configFetch[row.outcome as keyof typeof configFetch] = row.count
  }

  const installs = (
    db().prepare(`SELECT COUNT(DISTINCT install_id) AS n FROM diagnostic_events WHERE ${all.sql}`).get(...all.params) as {
      n: number
    }
  ).n

  return {
    chat: summarizeChats(chats),
    byConfigVersion: [...versions.entries()]
      .map(([configVersion, rows]) => ({ configVersion, ...summarizeChats(rows) }))
      .sort((a, b) => (a.configVersion < b.configVersion ? 1 : -1)),
    errorCodes,
    tools,
    configFetch,
    installs,
  }
}

export interface EventRow {
  id: number
  occurred_at: number
  install_id: string
  event_type: string
  outcome: string | null
  error_code: string | null
  result_code: string | null
  tool: string | null
  config_version: string | null
  model_alias: string | null
  request_id: string | null
  latency_ms: number
  rounds: number | null
  tool_calls: number | null
  tokens_in: number | null
  tokens_out: number | null
  claimed_card_without_tool: number | null
  app_version: string
}

export function recentEvents(filter: DiagnosticsFilter, limit = 100): EventRow[] {
  const w = where(filter)
  return db()
    .prepare(`SELECT * FROM diagnostic_events WHERE ${w.sql} ORDER BY occurred_at DESC, id DESC LIMIT ?`)
    .all(...w.params, limit) as unknown as EventRow[]
}

export function filterOptions() {
  const pluck = (sql: string) => (db().prepare(sql).all() as { v: string }[]).map((row) => row.v)
  return {
    configVersions: pluck(
      'SELECT DISTINCT config_version AS v FROM diagnostic_events WHERE config_version IS NOT NULL ORDER BY v DESC'
    ),
    appVersions: pluck('SELECT DISTINCT app_version AS v FROM diagnostic_events ORDER BY v DESC'),
  }
}

export interface InstallRow {
  install_id: string
  first_seen: number
  last_seen: number
  app_version: string
  os_version: string | null
  revoked: number
  events: number
}

export function listInstalls(): InstallRow[] {
  return db()
    .prepare(
      `SELECT i.*, (SELECT COUNT(*) FROM diagnostic_events e WHERE e.install_id = i.install_id) AS events
       FROM installs i ORDER BY last_seen DESC LIMIT 100`
    )
    .all() as unknown as InstallRow[]
}

/** 按安装 ID 删除它的全部诊断数据（§11.4）；revoke 时保留一行用来拒收之后的上报 */
export function deleteInstall(installId: string, revoke: boolean): number {
  const removed = db().prepare('DELETE FROM diagnostic_events WHERE install_id = ?').run(installId).changes
  if (revoke) {
    db().prepare('UPDATE installs SET revoked = 1 WHERE install_id = ?').run(installId)
  } else {
    db().prepare('DELETE FROM installs WHERE install_id = ?').run(installId)
  }
  return Number(removed)
}

export function setInstallRevoked(installId: string, revoked: boolean) {
  db().prepare('UPDATE installs SET revoked = ? WHERE install_id = ?').run(revoked ? 1 : 0, installId)
}
