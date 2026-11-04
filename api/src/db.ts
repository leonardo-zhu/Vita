/**
 * SQLite 存储，用 Node 内置的 node:sqlite（不引入原生依赖，ARM 镜像不用编译），做法同 Admin 与 Conduit。
 *
 * 库文件在 VITA_API_DATA_DIR（默认 api/.data/）下的 vita-api.db。
 * 表结构用 user_version 做迁移：MIGRATIONS 只追加，不改已有的条目。
 * 业务代码只经各模块的读写函数访问数据库，以后迁云数据库时只换这一层（《Vita 2.0 架构设计》§15）。
 */
import { mkdirSync } from 'node:fs'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'

const MIGRATIONS = [
  `-- 手机的设备令牌（架构设计 §8）。只存令牌的 sha256，明文签发时返回一次
  CREATE TABLE devices (
    id            TEXT PRIMARY KEY,        -- UUID
    name          TEXT NOT NULL,
    token_hash    TEXT NOT NULL UNIQUE,    -- 令牌明文的 sha256（hex）
    created_at    TEXT NOT NULL,           -- ISO 8601，UTC
    last_used_at  TEXT,
    revoked_at    TEXT
  );
  -- 技术审计，只追加：谁（admin / device:<id>）做了什么、结果如何
  CREATE TABLE audit_events (
    id           INTEGER PRIMARY KEY,
    occurred_at  TEXT NOT NULL,
    actor        TEXT NOT NULL,
    action       TEXT NOT NULL,
    target_id    TEXT NOT NULL DEFAULT '',
    result       TEXT NOT NULL,            -- success / failure
    error_code   TEXT
  );`,
]

export function dataDir(): string {
  return path.resolve(process.env.VITA_API_DATA_DIR ?? '.data')
}

/** 打开并迁移到最新版本。`:memory:` 给测试用。 */
export function openDatabase(file: string = path.join(dataDir(), 'vita-api.db')): DatabaseSync {
  if (file !== ':memory:') mkdirSync(path.dirname(file), { recursive: true })
  const database = new DatabaseSync(file)
  database.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;')
  migrate(database)
  return database
}

function migrate(database: DatabaseSync) {
  const { user_version: current } = database.prepare('PRAGMA user_version').get() as { user_version: number }
  if (current > MIGRATIONS.length) {
    throw new Error(`数据库版本 ${current} 比代码认识的 ${MIGRATIONS.length} 新，拒绝启动`)
  }
  for (let version = current; version < MIGRATIONS.length; version++) {
    database.exec('BEGIN')
    try {
      database.exec(MIGRATIONS[version])
      database.exec(`PRAGMA user_version = ${version + 1}`)
      database.exec('COMMIT')
    } catch (error) {
      database.exec('ROLLBACK')
      throw error
    }
  }
}

export function audit(
  database: DatabaseSync,
  entry: { actor: string; action: string; targetId?: string; result: 'success' | 'failure'; errorCode?: string; at: Date },
) {
  database
    .prepare('INSERT INTO audit_events (occurred_at, actor, action, target_id, result, error_code) VALUES (?, ?, ?, ?, ?, ?)')
    .run(entry.at.toISOString(), entry.actor, entry.action, entry.targetId ?? '', entry.result, entry.errorCode ?? null)
}
