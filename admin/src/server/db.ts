/**
 * SQLite 存储，用 Node 内置的 node:sqlite（不引入原生依赖，ARM 镜像不用编译），做法同 Conduit。
 *
 * 库文件在 VITA_ADMIN_DATA_DIR（默认 admin/.data/）下的 vita-admin.db。
 * 表结构用 user_version 做迁移：MIGRATIONS 只追加，不改已有的条目。
 * 设计见 docs/architecture/vita-admin.md §11.7。
 */
import { mkdirSync } from 'node:fs'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'

const MIGRATIONS = [
  `CREATE TABLE passkeys (
    id            TEXT PRIMARY KEY,        -- 凭据 ID（base64url）
    public_key    BLOB NOT NULL,           -- COSE 公钥
    counter       INTEGER NOT NULL DEFAULT 0,
    transports    TEXT NOT NULL DEFAULT '[]',
    name          TEXT NOT NULL,
    device_type   TEXT NOT NULL,           -- singleDevice / multiDevice
    backed_up     INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,        -- unix 秒
    last_used_at  INTEGER
  );
  -- 每个渠道一份当前草稿。content 是 DraftContent 的 JSON
  CREATE TABLE config_drafts (
    channel          TEXT PRIMARY KEY,
    content          TEXT NOT NULL,
    base_release_id  INTEGER,              -- 草稿基于哪个 release 编辑
    updated_by       TEXT NOT NULL,
    updated_at       INTEGER NOT NULL
  );
  -- 已发布的版本，不可变。content 是发布出去的完整文件；signature / key_id 为将来签名预留
  CREATE TABLE config_releases (
    id              INTEGER PRIMARY KEY,
    channel         TEXT NOT NULL,
    config_version  TEXT NOT NULL,
    content         TEXT NOT NULL,
    content_hash    TEXT NOT NULL,         -- content 的 sha256（hex）
    signature       TEXT,
    key_id          TEXT,
    published_by    TEXT NOT NULL,
    published_at    INTEGER NOT NULL,
    rollback_of     INTEGER REFERENCES config_releases(id),
    note            TEXT NOT NULL DEFAULT '',
    UNIQUE (channel, config_version)
  );
  CREATE TABLE channels (
    name                TEXT PRIMARY KEY,
    current_release_id  INTEGER REFERENCES config_releases(id)
  );
  INSERT INTO channels (name) VALUES ('stable');
  -- 变更审计，只追加
  CREATE TABLE admin_audit (
    id           INTEGER PRIMARY KEY,
    actor        TEXT NOT NULL,
    action       TEXT NOT NULL,
    target_type  TEXT NOT NULL DEFAULT '',
    target_id    TEXT NOT NULL DEFAULT '',
    diff         TEXT,                     -- JSON
    ip           TEXT NOT NULL DEFAULT '',
    at           INTEGER NOT NULL
  );
  CREATE TRIGGER admin_audit_no_update BEFORE UPDATE ON admin_audit
    BEGIN SELECT RAISE(ABORT, 'admin_audit is append-only'); END;
  CREATE TRIGGER admin_audit_no_delete BEFORE DELETE ON admin_audit
    BEGIN SELECT RAISE(ABORT, 'admin_audit is append-only'); END;`,
  // Prompt 试跑（vita-admin.md §11.2）：用哪份配置、发了什么、模型第一步回了什么
  `CREATE TABLE prompt_trials (
    id              INTEGER PRIMARY KEY,
    batch_id        TEXT NOT NULL,           -- 同一次点击里对比跑的几条共用
    source          TEXT NOT NULL,           -- draft / live
    config_version  TEXT,                    -- live 时是线上版本；没发布过或草稿为空
    model           TEXT NOT NULL,
    message         TEXT NOT NULL,
    context         TEXT NOT NULL,
    output          TEXT,                    -- JSON：{ text, reasoning, toolCalls }
    error           TEXT,
    request_id      TEXT NOT NULL,           -- X-Request-Id，可在 Conduit 日志里对上
    latency_ms      INTEGER NOT NULL,
    input_tokens    INTEGER,
    output_tokens   INTEGER,
    created_by      TEXT NOT NULL,
    created_at      INTEGER NOT NULL
  );
  CREATE INDEX prompt_trials_created ON prompt_trials (created_at DESC);`,
]

export function dataDir(): string {
  // 运行时才知道的目录，不让构建去追踪它（否则整个项目都会被拷进 standalone）
  return path.resolve(/*turbopackIgnore: true*/ process.env.VITA_ADMIN_DATA_DIR || '.data')
}

function open(): DatabaseSync {
  const dir = dataDir()
  mkdirSync(dir, { recursive: true })
  const database = new DatabaseSync(path.join(dir, 'vita-admin.db'))
  database.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;')
  return database
}

function migrate(database: DatabaseSync) {
  const { user_version: current } = database.prepare('PRAGMA user_version').get() as {
    user_version: number
  }
  for (let version = current; version < MIGRATIONS.length; version++) {
    transactionOn(database, () => {
      database.exec(MIGRATIONS[version])
      database.exec(`PRAGMA user_version = ${version + 1}`)
    })
  }
}

// 记下已迁移到的版本，热更新后 MIGRATIONS 变长了就补跑新的迁移
const globalRef = globalThis as typeof globalThis & {
  __vitaAdminDb?: DatabaseSync
  __vitaAdminDbVersion?: number
}

export function db(): DatabaseSync {
  globalRef.__vitaAdminDb ??= open()
  if (globalRef.__vitaAdminDbVersion !== MIGRATIONS.length) {
    migrate(globalRef.__vitaAdminDb)
    globalRef.__vitaAdminDbVersion = MIGRATIONS.length
  }
  return globalRef.__vitaAdminDb
}

/** 测试用：关掉当前连接，下次 db() 按新的 VITA_ADMIN_DATA_DIR 重新打开 */
export function resetDbForTests() {
  globalRef.__vitaAdminDb?.close()
  globalRef.__vitaAdminDb = undefined
  globalRef.__vitaAdminDbVersion = undefined
}

function transactionOn<T>(database: DatabaseSync, run: () => T): T {
  database.exec('BEGIN IMMEDIATE')
  try {
    const result = run()
    database.exec('COMMIT')
    return result
  } catch (error) {
    database.exec('ROLLBACK')
    throw error
  }
}

export function transaction<T>(run: () => T): T {
  return transactionOn(db(), run)
}

export const nowSeconds = () => Math.floor(Date.now() / 1000)

// ---------------------------------------------------------------------------
// passkeys
// ---------------------------------------------------------------------------

export interface PasskeyRow {
  id: string
  public_key: Uint8Array
  counter: number
  transports: string
  name: string
  device_type: string
  backed_up: number
  created_at: number
  last_used_at: number | null
}

export function listPasskeys(): PasskeyRow[] {
  return db().prepare('SELECT * FROM passkeys ORDER BY created_at').all() as unknown as PasskeyRow[]
}

export function getPasskey(id: string): PasskeyRow | undefined {
  return db().prepare('SELECT * FROM passkeys WHERE id = ?').get(id) as unknown as
    | PasskeyRow
    | undefined
}

export function insertPasskey(row: Omit<PasskeyRow, 'last_used_at'>) {
  db()
    .prepare(
      `INSERT INTO passkeys (id, public_key, counter, transports, name, device_type, backed_up, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      row.id,
      row.public_key,
      row.counter,
      row.transports,
      row.name,
      row.device_type,
      row.backed_up,
      row.created_at
    )
}

export function touchPasskey(id: string, counter: number, backedUp: boolean, now: number) {
  db()
    .prepare('UPDATE passkeys SET counter = ?, backed_up = ?, last_used_at = ? WHERE id = ?')
    .run(counter, backedUp ? 1 : 0, now, id)
}

export function deletePasskey(id: string): boolean {
  return db().prepare('DELETE FROM passkeys WHERE id = ?').run(id).changes > 0
}
