'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'

import { requireActor } from '@/server/actor'
import { recordAudit } from '@/server/audit'
import {
  AuthConfigError,
  adminUsername,
  checkCredentials,
  clearFailures,
  clientIp,
  endSession,
  isLockedOut,
  recordFailure,
  startSession,
} from '@/server/auth'
import { checkModelAlias } from '@/server/config/conduit'
import type { DraftContent } from '@/server/config/model'
import {
  PublishError,
  discardDraft,
  getDraft,
  preparePublish,
  publish,
  rollback,
  saveDraft,
} from '@/server/config/service'
import type { ValidationIssue } from '@/server/config/validate'
import { deletePasskey, getPasskey } from '@/server/db'
import { deleteInstall, setInstallRevoked } from '@/server/diagnostics/query'
import { conduitConfigured, runTrials, type TrialRun, type TrialSource } from '@/server/trial'

export type ActionResult =
  | { ok: true; message?: string; warning?: string }
  | { ok: false; message: string; issues?: ValidationIssue[] }

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------

export async function loginAction(_: ActionResult | null, form: FormData): Promise<ActionResult> {
  const ip = await clientIp()
  if (isLockedOut(ip)) return { ok: false, message: '失败次数太多，请 15 分钟后再试' }
  const username = String(form.get('username') ?? '')
  const password = String(form.get('password') ?? '')
  let valid: boolean
  try {
    valid = checkCredentials(username, password)
  } catch (error) {
    if (error instanceof AuthConfigError) return { ok: false, message: error.message }
    throw error
  }
  if (!valid) {
    recordFailure(ip)
    recordAudit({ actor: username || '(空)', action: 'login_failed', ip })
    return { ok: false, message: '账号或密码不对' }
  }
  clearFailures(ip)
  await startSession('password')
  recordAudit({ actor: adminUsername(), action: 'login', diff: { method: 'password' }, ip })
  redirect('/admin')
}

export async function logoutAction() {
  const actor = await requireActor()
  await endSession()
  recordAudit({ actor: actor.name, action: 'logout', ip: actor.ip })
  redirect('/admin/login')
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

export async function saveDraftAction(content: DraftContent): Promise<ActionResult> {
  const actor = await requireActor()
  try {
    saveDraft(content, actor)
  } catch (error) {
    return { ok: false, message: `草稿格式不对：${(error as Error).message}` }
  }
  revalidatePath('/admin')
  const { issues } = preparePublish()
  return issues.length
    ? { ok: true, message: '草稿已保存', warning: `还有 ${issues.length} 处没通过校验，修好才能发布` }
    : { ok: true, message: '草稿已保存' }
}

export async function discardDraftAction(): Promise<ActionResult> {
  const actor = await requireActor()
  discardDraft(actor)
  revalidatePath('/admin')
  return { ok: true, message: '已放弃修改' }
}

export async function publishAction(note: string): Promise<ActionResult> {
  const actor = await requireActor()
  const alias = await checkModelAlias(getDraft().content.llm.modelId)
  if (alias.status === 'missing') {
    return { ok: false, message: alias.message, issues: [{ path: '/llm/modelId', message: alias.message }] }
  }
  try {
    const release = publish(note, actor)
    revalidatePath('/admin', 'layout')
    return {
      ok: true,
      message: `已发布 ${release.config_version}`,
      warning: alias.status === 'ok' ? undefined : alias.message,
    }
  } catch (error) {
    if (error instanceof PublishError) return { ok: false, message: error.message, issues: error.issues }
    throw error
  }
}

export async function rollbackAction(releaseId: number): Promise<ActionResult> {
  const actor = await requireActor()
  try {
    const release = rollback(releaseId, actor)
    revalidatePath('/admin', 'layout')
    return { ok: true, message: `已发布 ${release.config_version}（回滚）` }
  } catch (error) {
    if (error instanceof PublishError) return { ok: false, message: error.message, issues: error.issues }
    throw error
  }
}

// ---------------------------------------------------------------------------
// Passkey（注册走 /api/passkey/register/*，需要浏览器的 WebAuthn）
// ---------------------------------------------------------------------------

export async function deletePasskeyAction(id: string): Promise<ActionResult> {
  const actor = await requireActor()
  const row = getPasskey(id)
  if (!row || !deletePasskey(id)) return { ok: false, message: '这个 Passkey 已经不存在' }
  recordAudit({ actor: actor.name, action: 'passkey_remove', targetType: 'passkey', targetId: row.name, ip: actor.ip })
  revalidatePath('/admin/settings')
  return { ok: true, message: `已删除 ${row.name}` }
}

// ---------------------------------------------------------------------------
// Prompt 试跑
// ---------------------------------------------------------------------------

export type TrialMode = 'draft' | 'live' | 'both'

export async function runTrialAction(input: {
  mode: TrialMode
  message: string
  context: string
}): Promise<{ ok: true; runs: TrialRun[] } | { ok: false; message: string }> {
  const actor = await requireActor()
  if (!conduitConfigured()) return { ok: false, message: '没有配置 CONDUIT_BASE_URL / CONDUIT_API_KEY，不能试跑' }
  const message = input.message.trim()
  if (!message) return { ok: false, message: '先写一句用户消息' }
  if (message.length > 2000 || input.context.length > 20000) return { ok: false, message: '内容太长' }
  const sources: TrialSource[] = input.mode === 'both' ? ['live', 'draft'] : [input.mode]
  const runs = await runTrials(sources, message, input.context, actor)
  revalidatePath('/admin/trial')
  return { ok: true, runs }
}

// ---------------------------------------------------------------------------
// 诊断日志：按安装 ID 删除或封禁（vita-admin.md §11.4）
// ---------------------------------------------------------------------------

const INSTALL_ID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/

export async function deleteInstallAction(installId: string): Promise<ActionResult> {
  const actor = await requireActor()
  if (!INSTALL_ID.test(installId)) return { ok: false, message: '安装 ID 格式不对' }
  const removed = deleteInstall(installId, false)
  recordAudit({ actor: actor.name, action: 'install_delete', targetType: 'install', targetId: installId, diff: { removed }, ip: actor.ip })
  revalidatePath('/admin/diagnostics')
  return { ok: true, message: `已删除 ${removed} 条诊断记录` }
}

export async function setInstallRevokedAction(installId: string, revoked: boolean): Promise<ActionResult> {
  const actor = await requireActor()
  if (!INSTALL_ID.test(installId)) return { ok: false, message: '安装 ID 格式不对' }
  setInstallRevoked(installId, revoked)
  recordAudit({ actor: actor.name, action: 'install_revoke', targetType: 'install', targetId: installId, diff: { revoked }, ip: actor.ip })
  revalidatePath('/admin/diagnostics')
  return { ok: true, message: revoked ? '已封禁，之后的上报会被拒收' : '已解封' }
}
