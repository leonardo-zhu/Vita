'use server'

/**
 * 对话与数据管理（M4）：都经 Vita API，校验与审计在 API；这里再记一条 Admin 的审计，写明是谁在哪改的。
 */
import { revalidatePath } from 'next/cache'

import type { Messages } from '@/i18n/messages'
import { getT } from '@/i18n/server'
import { requireActor } from '@/server/actor'
import { recordAudit, type AuditAction } from '@/server/audit'
import { deleteFood, deleteItem, deleteRecord, rescaleItem, setMessageExcluded, updateFood, VitaApiError } from '@/server/vita-api'

import type { ActionResult } from './actions'

function errorText(t: Messages, error: unknown): string {
  if (error instanceof VitaApiError) {
    if (error.code === 'notConfigured') return t.devices.errors.notConfigured
    if (error.code === 'unreachable') return t.devices.errors.unreachable
    if (error.code === 'revisionConflict') return t.data.revisionConflict
    return t.devices.errors.api(error.message)
  }
  return t.devices.errors.api((error as Error).message)
}

async function run(
  audit: { action: AuditAction; targetType: string; targetId: string; diff: Record<string, unknown> },
  path: string,
  body: () => Promise<unknown>
): Promise<ActionResult> {
  const actor = await requireActor()
  const t = await getT()
  try {
    await body()
  } catch (error) {
    return { ok: false, message: errorText(t, error) }
  }
  recordAudit({ actor: actor.name, ...audit, ip: actor.ip })
  revalidatePath(path)
  return { ok: true, message: t.data.saved }
}

export async function setMessageExcludedAction(id: string, excluded: boolean): Promise<ActionResult> {
  return run({ action: excluded ? 'message_exclude' : 'message_include', targetType: 'message', targetId: id, diff: { excluded } }, '/admin/conversations', () =>
    setMessageExcluded(id, excluded)
  )
}

export async function deleteRecordAction(date: string, revision: number, recordId: string): Promise<ActionResult> {
  return run({ action: 'record_delete', targetType: 'record', targetId: recordId, diff: { date } }, '/admin/records', () => deleteRecord(date, revision, recordId))
}

export async function deleteItemAction(date: string, revision: number, recordId: string, itemId: string): Promise<ActionResult> {
  return run({ action: 'item_delete', targetType: 'item', targetId: itemId, diff: { date, recordId } }, '/admin/records', () =>
    deleteItem(date, revision, recordId, itemId)
  )
}

/** quantity 有单位时按新用量重算，否则按倍数缩放。 */
export async function rescaleItemAction(
  date: string,
  revision: number,
  recordId: string,
  itemId: string,
  change: { quantity: { amount: number; unit: 'g' | 'ml' } } | { factor: number }
): Promise<ActionResult> {
  return run({ action: 'item_rescale', targetType: 'item', targetId: itemId, diff: { date, recordId, ...change } }, '/admin/records', () =>
    rescaleItem(date, recordId, itemId, { expectedRevision: revision, ...change })
  )
}

export async function updateFoodAction(id: string, name: string, brandOrSupplier: string): Promise<ActionResult> {
  const t = await getT()
  const trimmed = name.trim()
  if (!trimmed || trimmed.length > 80) return { ok: false, message: t.data.badName }
  const brand = brandOrSupplier.trim() || null
  return run({ action: 'food_update', targetType: 'food', targetId: id, diff: { name: trimmed, brand } }, '/admin/foods', () =>
    updateFood(id, { name: trimmed, brandOrSupplier: brand })
  )
}

export async function deleteFoodAction(id: string, name: string): Promise<ActionResult> {
  return run({ action: 'food_delete', targetType: 'food', targetId: id, diff: { name } }, '/admin/foods', () => deleteFood(id))
}
