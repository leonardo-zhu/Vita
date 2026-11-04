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
  `-- 业务数据（TDD §3，对应 1.0 的 SwiftData 模型）。时刻一律是 ISO 8601（UTC），JSON 列存领域对象
  -- 每个日期一个，revision 每次正式写入递增；提案带上它，确认时不一致即拒绝（TDD §5.2）
  CREATE TABLE day_sessions (
    local_date  TEXT PRIMARY KEY,          -- YYYY-MM-DD
    time_zone   TEXT NOT NULL,             -- 创建时固定，之后不重写
    revision    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );
  CREATE TABLE consumption_records (
    id            TEXT PRIMARY KEY,
    session_date  TEXT NOT NULL REFERENCES day_sessions(local_date) ON DELETE CASCADE,
    event_time    TEXT NOT NULL,           -- EventTime JSON
    sort_time     TEXT NOT NULL,           -- 代表性时刻，只用于排序
    meal_label    TEXT,
    note          TEXT,
    revision      INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
  );
  CREATE INDEX consumption_records_session ON consumption_records(session_date);
  -- 营养快照在创建 / 修改时写定，之后不随食品版本或参考库变化
  CREATE TABLE consumption_items (
    id                    TEXT PRIMARY KEY,
    record_id             TEXT NOT NULL REFERENCES consumption_records(id) ON DELETE CASCADE,
    position              INTEGER NOT NULL,
    group_name            TEXT,
    display_name          TEXT NOT NULL,
    original_amount_text  TEXT NOT NULL,
    quantity              TEXT,            -- Quantity JSON
    amount_source         TEXT NOT NULL,
    snapshot              TEXT NOT NULL,   -- NutritionSnapshot JSON
    include_in_summary    INTEGER NOT NULL,
    food_product_id       TEXT,
    food_version_id       TEXT,
    reference_food_id     TEXT,
    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL
  );
  CREATE INDEX consumption_items_record ON consumption_items(record_id);
  CREATE TABLE food_products (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL,
    brand_or_supplier  TEXT,
    package            TEXT,               -- Quantity JSON
    note               TEXT,
    active_version_id  TEXT,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );
  -- 不可变：创建后不修改，纠正时新建版本并切换生效版本（TDD §4.3）
  CREATE TABLE food_versions (
    id                         TEXT PRIMARY KEY,
    product_id                 TEXT NOT NULL REFERENCES food_products(id) ON DELETE CASCADE,
    basis                      TEXT NOT NULL,  -- FoodVersionBasis JSON
    source_kind                TEXT NOT NULL,
    label_scan_id              TEXT,
    derived_from_reference_id  TEXT,
    source_note                TEXT,
    created_at                 TEXT NOT NULL,
    retired_at                 TEXT
  );
  CREATE INDEX food_versions_product ON food_versions(product_id);
  -- 营养标签照片的存档记录；照片文件本身随 M3 的上传接口落地
  CREATE TABLE label_scans (
    id          TEXT PRIMARY KEY,
    created_at  TEXT NOT NULL
  );
  -- 确认卡（ADR-004、ADR-008）。每个日期最多一张待确认；payload 是确认时原样执行的变更
  CREATE TABLE pending_actions (
    id                 TEXT PRIMARY KEY,
    session_date       TEXT NOT NULL,
    expected_revision  INTEGER NOT NULL,
    payload            TEXT,               -- PendingChange JSON；结束后保留，用于审计
    payload_hash       TEXT NOT NULL,      -- payload 的 sha256，确认前核对
    preview            TEXT,               -- 确认卡内容 JSON；结束后清空
    status             TEXT NOT NULL,      -- readyForConfirmation / confirmed / cancelled / expired
    created_at         TEXT NOT NULL,
    expires_at         TEXT NOT NULL,
    resolved_at        TEXT,
    resolution_code    TEXT,
    result_id          TEXT,
    request_id         TEXT,
    after_confirm      TEXT
  );
  CREATE INDEX pending_actions_active ON pending_actions(session_date, status);
  ALTER TABLE audit_events ADD COLUMN request_id TEXT;`,
  `-- 每日目标：只追加。某日生效的是 effective_from 不晚于该日的行中日期最晚、revision 最高的一行（TDD §3.2）
  CREATE TABLE daily_goals (
    id              TEXT PRIMARY KEY,
    effective_from  TEXT NOT NULL,         -- YYYY-MM-DD
    targets         TEXT NOT NULL,         -- GoalTargets JSON
    energy_plan     TEXT,                  -- EnergyPlan JSON；没有时是固定能量目标
    origin          TEXT NOT NULL,
    evidence        TEXT,                  -- 生成依据（如 GoalRecommendation）JSON
    revision        INTEGER NOT NULL UNIQUE,
    created_at      TEXT NOT NULL
  );
  -- 手机上传的每日活动能量（Apple 健康）。今天的是截至上传时的累计
  CREATE TABLE day_activity (
    local_date   TEXT PRIMARY KEY,
    active_kcal  REAL,                     -- 没有数据为 NULL
    updated_at   TEXT NOT NULL
  );
  -- 手机最近一次上传的身体数据（HealthUpload JSON），只留一份
  CREATE TABLE health_upload (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    data         TEXT NOT NULL,
    uploaded_at  TEXT NOT NULL
  );
  -- 用户补录的身体数据，只留一份；只用于目标生成，不写回 Apple 健康
  CREATE TABLE manual_body_metrics (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    data        TEXT NOT NULL,             -- ManualBodyMetrics JSON
    entered_at  TEXT NOT NULL
  );`,
  `-- 体脂秤的原始称重（身体成分模块 §5）：只存秤测到的体重与阻抗，体脂率等指标读取时再算，算法或校准更新后历史一起重算。
  -- 秤确认离线记录后就删掉了，这里是唯一一份；写进 Apple 健康的 Sample 由手机记录
  CREATE TABLE scale_weighings (
    id                       TEXT PRIMARY KEY,   -- 手机生成，重传不重复
    measured_at              TEXT NOT NULL,
    weight_grams             INTEGER NOT NULL,
    impedance_a              INTEGER,
    impedance_b              INTEGER,
    source                   TEXT NOT NULL,      -- live / offline
    time_reliable            INTEGER NOT NULL,   -- 0：离线记录没有可靠时间，measured_at 是同步时间
    profile                  TEXT NOT NULL,      -- 称重时的身高、年龄、性别 JSON
    scale_body_fat_permille  INTEGER,            -- 用户照着秤屏幕记下的体脂率（千分比），用来校准
    created_at               TEXT NOT NULL
  );
  CREATE INDEX scale_weighings_time ON scale_weighings(measured_at);`,
  `-- 对话（TDD §3.4）：按日期组织，只存用户与助手的文字和附带的卡片引用，不存工具 payload
  CREATE TABLE chat_messages (
    id            TEXT PRIMARY KEY,
    session_date  TEXT NOT NULL,
    role          TEXT NOT NULL,           -- user / assistant
    text          TEXT NOT NULL,
    card_ref      TEXT,                    -- pending:<id> 或 label:<id>
    created_at    TEXT NOT NULL
  );
  CREATE INDEX chat_messages_session ON chat_messages(session_date, created_at);
  -- 对话追踪（架构设计 §10.3）：每轮的原话、回复、推理、工具调用与结果，只在 Admin 里看，保留 90 天
  CREATE TABLE chat_traces (
    request_id             TEXT PRIMARY KEY,
    session_date           TEXT NOT NULL,
    kind                   TEXT NOT NULL,  -- message：用户发消息；continuation：确认后接续
    config_version         TEXT NOT NULL,
    system_prompt_version  INTEGER NOT NULL,
    model                  TEXT NOT NULL,
    input_text             TEXT NOT NULL,  -- 用户原话，或接续时给模型的提示
    label_scan_id          TEXT,
    reply                  TEXT,
    reasoning              TEXT,
    steps                  TEXT NOT NULL,  -- [{tool, arguments, output, resultCode}] JSON
    pending_id             TEXT,
    outcome                TEXT NOT NULL,  -- ok / error / cancelled
    error_code             TEXT,
    rounds                 INTEGER NOT NULL,
    tokens_in              INTEGER,
    tokens_out             INTEGER,
    tokens_cached          INTEGER,
    hit_max_rounds         INTEGER NOT NULL,
    latency_ms             INTEGER NOT NULL,
    created_at             TEXT NOT NULL
  );
  CREATE INDEX chat_traces_time ON chat_traces(created_at);
  -- 标签照片文件（ADR-016）：手机压缩后上传，存在文件目录，库里只记引用
  ALTER TABLE label_scans ADD COLUMN file TEXT;
  ALTER TABLE label_scans ADD COLUMN content_type TEXT;
  -- 确认后的接续只跑一次
  ALTER TABLE pending_actions ADD COLUMN continued_at TEXT;`,
  `-- Apple 健康同步的变更流（架构设计 §9）：饮食记录或称重每变一次记一条，手机按游标拉取，按最新状态覆盖健康里的那份
  CREATE TABLE health_changes (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    entity      TEXT NOT NULL,             -- record / weighing
    entity_id   TEXT NOT NULL,
    created_at  TEXT NOT NULL
  );
  CREATE INDEX health_changes_entity ON health_changes(entity, entity_id);`,
  `-- 一条消息可以带多张标签照片（批量录入）：按顺序存 JSON 数组。card_ref 仍记第一张，只认一张的旧客户端照样显示
  ALTER TABLE chat_messages ADD COLUMN label_scan_ids TEXT;
  ALTER TABLE chat_traces ADD COLUMN label_scan_ids TEXT;`,
  `-- 删除个人食品（M4）：只做标记，不再出现在食品库与模型的上下文里；已有记录的营养快照与来源名不受影响
  ALTER TABLE food_products ADD COLUMN deleted_at TEXT;`,
  `-- Admin 把消息排除出模型的上下文（rewind）：消息照常显示与保留，只是不再发给模型
  ALTER TABLE chat_messages ADD COLUMN excluded_at TEXT;`,
]

/** 在调用方的事务里登记一次变化，供手机同步到 Apple 健康。 */
export function recordHealthChange(database: DatabaseSync, entity: 'record' | 'weighing', id: string, at: Date) {
  database.prepare('INSERT INTO health_changes (entity, entity_id, created_at) VALUES (?, ?, ?)').run(entity, id, at.toISOString())
}

/**
 * 在一个事务里执行 `body`，失败时回滚并把错误抛出。不能嵌套：内层需要同一事务时由外层传入回调（见 records.apply 的 alongside）。
 */
export function transaction<T>(database: DatabaseSync, body: () => T): T {
  database.exec('BEGIN IMMEDIATE')
  try {
    const result = body()
    database.exec('COMMIT')
    return result
  } catch (error) {
    database.exec('ROLLBACK')
    throw error
  }
}

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

export interface AuditEntry {
  actor: string
  action: string
  targetId?: string | null
  result: 'success' | 'failure'
  errorCode?: string | null
  requestId?: string | null
  at: Date
}

export function audit(database: DatabaseSync, entry: AuditEntry) {
  database
    .prepare('INSERT INTO audit_events (occurred_at, actor, action, target_id, result, error_code, request_id) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .run(entry.at.toISOString(), entry.actor, entry.action, entry.targetId ?? '', entry.result, entry.errorCode ?? null, entry.requestId ?? null)
}
