'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'

import type { Messages } from '@/i18n/messages'
import { getT } from '@/i18n/server'
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
import { createDevice, revokeDevice, VitaApiError } from '@/server/vita-api'

export type ActionResult =
  | { ok: true; message?: string; warning?: string }
  | { ok: false; message: string; issues?: ValidationIssue[] }

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------

export async function loginAction(_: ActionResult | null, form: FormData): Promise<ActionResult> {
  const t = await getT()
  const ip = await clientIp()
  if (isLockedOut(ip)) return { ok: false, message: t.login.lockedOut }
  const username = String(form.get('username') ?? '')
  const password = String(form.get('password') ?? '')
  let valid: boolean
  try {
    valid = checkCredentials(username, password)
  } catch (error) {
    if (error instanceof AuthConfigError) return { ok: false, message: t.login.notConfigured }
    throw error
  }
  if (!valid) {
    recordFailure(ip)
    recordAudit({ actor: username || '(empty)', action: 'login_failed', ip })
    return { ok: false, message: t.login.wrong }
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
  const t = await getT()
  try {
    saveDraft(content, actor)
  } catch (error) {
    return { ok: false, message: t.actions.draftInvalid((error as Error).message) }
  }
  revalidatePath('/admin')
  const { issues } = preparePublish()
  return issues.length
    ? { ok: true, message: t.actions.draftSaved, warning: t.actions.draftHasIssues(issues.length) }
    : { ok: true, message: t.actions.draftSaved }
}

export async function discardDraftAction(): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  discardDraft(actor)
  revalidatePath('/admin')
  return { ok: true, message: t.actions.draftDiscarded }
}

function publishFailure(t: Messages, error: PublishError): ActionResult {
  const message = {
    invalid: t.actions.publishInvalid,
    releaseNotFound: t.actions.releaseNotFound,
    rollbackInvalid: t.actions.rollbackInvalid,
  }[error.code]
  return { ok: false, message, issues: error.issues }
}

export async function publishAction(note: string): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  const alias = await checkModelAlias(getDraft().content.llm.modelId)
  if (alias.status === 'missing') {
    const message = t.issues.rule.aliasMissing('', alias.alias)
    return { ok: false, message, issues: [{ path: '/llm/modelId', rule: 'aliasMissing', param: alias.alias }] }
  }
  try {
    const release = publish(note, actor)
    revalidatePath('/admin', 'layout')
    const warning =
      alias.status === 'skipped' ? t.actions.aliasSkipped : alias.status === 'error' ? t.actions.aliasError(alias.detail) : undefined
    return { ok: true, message: t.actions.published(release.config_version), warning }
  } catch (error) {
    if (error instanceof PublishError) return publishFailure(t, error)
    throw error
  }
}

export async function rollbackAction(releaseId: number): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  try {
    const release = rollback(releaseId, actor)
    revalidatePath('/admin', 'layout')
    return { ok: true, message: t.actions.rolledBack(release.config_version) }
  } catch (error) {
    if (error instanceof PublishError) return publishFailure(t, error)
    throw error
  }
}

// ---------------------------------------------------------------------------
// Passkey（注册走 /api/passkey/register/*，需要浏览器的 WebAuthn）
// ---------------------------------------------------------------------------

export async function deletePasskeyAction(id: string): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  const row = getPasskey(id)
  if (!row || !deletePasskey(id)) return { ok: false, message: t.actions.passkeyGone }
  recordAudit({ actor: actor.name, action: 'passkey_remove', targetType: 'passkey', targetId: row.name, ip: actor.ip })
  revalidatePath('/admin/settings')
  return { ok: true, message: t.actions.passkeyDeleted(row.name) }
}

// ---------------------------------------------------------------------------
// Prompt 调试
// ---------------------------------------------------------------------------

export type TrialMode = 'draft' | 'live' | 'both'

export async function runTrialAction(input: {
  mode: TrialMode
  message: string
  context: string
}): Promise<{ ok: true; runs: TrialRun[] } | { ok: false; message: string }> {
  const actor = await requireActor()
  const t = await getT()
  if (!conduitConfigured()) return { ok: false, message: t.playground.errors.notConfigured }
  const message = input.message.trim()
  if (!message) return { ok: false, message: t.playground.errors.emptyMessage }
  if (message.length > 2000 || input.context.length > 20000) return { ok: false, message: t.playground.errors.tooLong }
  const sources: TrialSource[] = input.mode === 'both' ? ['live', 'draft'] : [input.mode]
  const runs = await runTrials(sources, message, input.context, actor)
  revalidatePath('/admin/playground')
  return { ok: true, runs }
}

// ---------------------------------------------------------------------------
// 诊断日志：按安装 ID 删除或封禁（vita-admin.md §11.4）
// ---------------------------------------------------------------------------

const INSTALL_ID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/

export async function deleteInstallAction(installId: string): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  if (!INSTALL_ID.test(installId)) return { ok: false, message: t.actions.badInstallId }
  const removed = deleteInstall(installId, false)
  recordAudit({ actor: actor.name, action: 'install_delete', targetType: 'install', targetId: installId, diff: { removed }, ip: actor.ip })
  revalidatePath('/admin/diagnostics')
  return { ok: true, message: t.actions.installDeleted(removed) }
}

export async function setInstallRevokedAction(installId: string, revoked: boolean): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  if (!INSTALL_ID.test(installId)) return { ok: false, message: t.actions.badInstallId }
  setInstallRevoked(installId, revoked)
  recordAudit({ actor: actor.name, action: 'install_revoke', targetType: 'install', targetId: installId, diff: { revoked }, ip: actor.ip })
  revalidatePath('/admin/diagnostics')
  return { ok: true, message: revoked ? t.actions.installRevoked : t.actions.installRestored }
}

// ---------------------------------------------------------------------------
// 设备令牌（经 Vita API 签发与吊销）
// ---------------------------------------------------------------------------

/** 签发后令牌只在这次返回里出现，页面展示一次，之后看不到。 */
export async function createDeviceAction(
  name: string
): Promise<{ ok: true; token: string; deviceName: string } | { ok: false; message: string }> {
  const actor = await requireActor()
  const t = await getT()
  const trimmed = name.trim()
  if (!trimmed || trimmed.length > 64) return { ok: false, message: t.devices.errors.badName }
  try {
    const { device, token } = await createDevice(trimmed)
    recordAudit({ actor: actor.name, action: 'device_create', targetType: 'device', targetId: device.id, diff: { name: device.name }, ip: actor.ip })
    revalidatePath('/admin/devices')
    return { ok: true, token, deviceName: device.name }
  } catch (error) {
    return { ok: false, message: deviceErrorText(t, error) }
  }
}

export async function revokeDeviceAction(id: string, name: string): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  try {
    await revokeDevice(id)
  } catch (error) {
    return { ok: false, message: deviceErrorText(t, error) }
  }
  recordAudit({ actor: actor.name, action: 'device_revoke', targetType: 'device', targetId: id, diff: { name }, ip: actor.ip })
  revalidatePath('/admin/devices')
  return { ok: true, message: t.devices.revoked(name) }
}

function deviceErrorText(t: Messages, error: unknown): string {
  if (error instanceof VitaApiError) {
    if (error.code === 'notConfigured') return t.devices.errors.notConfigured
    if (error.code === 'unreachable') return t.devices.errors.unreachable
    if (error.code === 'deviceNotFound') return t.devices.errors.notFound
    return t.devices.errors.api(error.message)
  }
  return t.devices.errors.api((error as Error).message)
}
