'use server'

/**
 * 对话与数据管理（M4）：都经 Vita API，校验与审计在 API；这里再记一条 Admin 的审计，写明是谁在哪改的。
 */
import { revalidatePath } from 'next/cache'

import type { Messages } from '@/i18n/messages'
import { getT } from '@/i18n/server'
import { requireActor } from '@/server/actor'
import { recordAudit, type AuditAction } from '@/server/audit'
import { addFoodVersion, deleteFood, deleteItem, deleteRecord, rescaleItem, setMessageExcluded, updateFood, VitaApiError } from '@/server/vita-api'

import type { ActionResult } from './actions'

function errorText(t: Messages, error: unknown): string {
  if (error instanceof VitaApiError) {
    if (error.code === 'notConfigured') return t.devices.errors.notConfigured
    if (error.code === 'unreachable') return t.devices.errors.unreachable
    if (error.code === 'revisionConflict') return t.data.revisionConflict
    if (error.code === 'activeVersionChanged') return t.data.versionConflict
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

export interface FoodInfoForm {
  name: string
  brand: string
  /** 顿号、逗号或分号隔开。 */
  aliases: string
  /** 净含量，空表示不记。 */
  packageAmount: string
  packageUnit: 'g' | 'ml'
  note: string
}

export async function updateFoodAction(id: string, form: FoodInfoForm): Promise<ActionResult> {
  const t = await getT()
  const name = form.name.trim()
  if (!name || name.length > 80) return { ok: false, message: t.data.badName }
  const amountText = form.packageAmount.trim()
  const amount = Number(amountText)
  if (amountText && !(Number.isFinite(amount) && amount > 0)) return { ok: false, message: t.data.badAmount }
  const body = {
    name,
    brandOrSupplier: form.brand.trim() || null,
    aliases: form.aliases
      .split(/[、,，;；]/)
      .map((alias) => alias.trim())
      .filter(Boolean)
      .slice(0, 20),
    package: amountText ? { amount, unit: form.packageUnit } : null,
    note: form.note.trim() || null,
  }
  return run({ action: 'food_update', targetType: 'food', targetId: id, diff: body }, '/admin/foods', () => updateFood(id, body))
}

export interface FoodNutritionForm {
  basisAmount: string
  basisUnit: 'g' | 'ml'
  energyKcal: string
  proteinG: string
  fatG: string
  carbohydrateG: string
  /** 选填：空表示来源上没有。 */
  sodiumMg: string
  saturatedFatG: string
  sugarG: string
  sourceNote: string
}

/** 改营养值：存为新版本。expectedActiveVersionId 是打开表单时的生效版本，期间被别处改过会拒绝。 */
export async function addFoodVersionAction(id: string, expectedActiveVersionId: string | null, form: FoodNutritionForm): Promise<ActionResult> {
  const t = await getT()
  const number = (text: string) => (text.trim() === '' ? null : Number(text.trim()))
  const basisAmount = number(form.basisAmount)
  const required = [form.energyKcal, form.proteinG, form.fatG, form.carbohydrateG].map(number)
  const extras = { sodiumMg: number(form.sodiumMg), saturatedFatG: number(form.saturatedFatG), sugarG: number(form.sugarG) }
  const valid = (value: number | null) => value !== null && Number.isFinite(value) && value >= 0
  if (!(basisAmount && basisAmount > 0) || !required.every(valid) || !Object.values(extras).every((value) => value === null || valid(value))) {
    return { ok: false, message: t.data.badNutrition }
  }
  const [energyKcal, proteinG, fatG, carbohydrateG] = required as number[]
  const nutrients = {
    energyKcal,
    proteinG,
    fatG,
    carbohydrateG,
    ...Object.fromEntries(Object.entries(extras).filter(([, value]) => value !== null)),
  }
  const body = {
    expectedActiveVersionId,
    basis: { quantity: { amount: basisAmount, unit: form.basisUnit }, nutrients },
    sourceNote: form.sourceNote.trim() || t.data.manualVersionNote,
  }
  return run({ action: 'food_version', targetType: 'food', targetId: id, diff: body }, '/admin/foods', () => addFoodVersion(id, body))
}

export async function deleteFoodAction(id: string, name: string): Promise<ActionResult> {
  return run({ action: 'food_delete', targetType: 'food', targetId: id, diff: { name } }, '/admin/foods', () => deleteFood(id))
}
