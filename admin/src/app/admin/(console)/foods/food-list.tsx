'use client'

import type { FoodVersionBasis, Quantity } from '@vita/contract'
import { ChevronDown, History, Pencil, Trash2 } from 'lucide-react'
import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useT } from '@/i18n/client'
import { cn } from '@/lib/utils'

import type { ActionResult } from '../../actions'
import { addFoodVersionAction, deleteFoodAction, updateFoodAction, type FoodInfoForm, type FoodNutritionForm } from '../../data-actions'

interface VersionRow {
  id: string
  active: boolean
  basis: FoodVersionBasis
  source: 'nutritionLabel' | 'manualEntry' | 'referenceDerived'
  sourceNote: string | null
  createdAt: string
}

interface FoodRow {
  id: string
  name: string
  brand: string | null
  aliases: string[]
  note: string | null
  package: Quantity | null
  activeVersionId: string | null
  labelScanId: string | null
  /** 新的在前。 */
  versions: VersionRow[]
}

const EXTRAS = [
  ['sodiumMg', 'Na', 'mg'],
  ['saturatedFatG', 'SFA', 'g'],
  ['sugarG', 'Sugar', 'g'],
] as const

function nutrientsText(basis: FoodVersionBasis): string {
  const n = basis.nutrients
  const extras = EXTRAS.flatMap(([key, label, unit]) => (n[key] === undefined ? [] : [`${label} ${n[key]} ${unit}`]))
  return [`${Math.round(n.energyKcal)} kcal`, `P ${n.proteinG} g`, `F ${n.fatG} g`, `C ${n.carbohydrateG} g`, ...extras].join(' · ')
}

export function FoodList({ products }: { products: FoodRow[] }) {
  const t = useT()
  const [pending, startTransition] = useTransition()
  const [open, setOpen] = useState<{ id: string; panel: 'edit' | 'history' } | null>(null)

  function run(action: () => Promise<ActionResult>, after?: () => void) {
    startTransition(async () => {
      const result = await action()
      if (result.ok) {
        toast.success(result.message ?? t.data.saved)
        after?.()
      } else toast.error(result.message)
    })
  }

  function toggle(id: string, panel: 'edit' | 'history') {
    setOpen(open?.id === id && open.panel === panel ? null : { id, panel })
  }

  return (
    <div className="flex flex-col gap-3">
      {products.map((product) => {
        const active = product.versions.find((version) => version.active)
        const isOpen = open?.id === product.id
        return (
          <div key={product.id} className={cn('rounded-lg border text-sm', isOpen && 'border-primary/40')}>
            <div className="flex flex-wrap items-start gap-3 px-3 py-2">
              {product.labelScanId && (
                <a href={`/admin/labels/${product.labelScanId}`} target="_blank" rel="noreferrer" className="shrink-0">
                  {/* eslint-disable-next-line @next/next/no-img-element -- 经 Admin 转发的私有照片 */}
                  <img src={`/admin/labels/${product.labelScanId}`} alt={t.data.labelPhoto} className="h-16 w-16 rounded border object-cover" />
                </a>
              )}
              <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                <span className="font-medium">
                  {product.name}
                  {product.brand && <span className="ml-2 text-xs font-normal text-muted-foreground">{product.brand}</span>}
                </span>
                {product.aliases.length > 0 && <span className="text-xs text-muted-foreground">{t.data.alsoCalled(product.aliases.join('、'))}</span>}
                {active && (
                  <span className="text-xs text-muted-foreground tabular-nums">
                    {t.data.perBasis(`${active.basis.quantity.amount} ${active.basis.quantity.unit}`)}：{nutrientsText(active.basis)}
                  </span>
                )}
                <span className="text-xs text-muted-foreground">
                  {product.package ? `${t.data.packageLabel} ${product.package.amount} ${product.package.unit}` : t.data.noPackage}
                  {' · '}
                  {t.data.versions(product.versions.length)}
                </span>
              </div>
              <div className="flex gap-1">
                <Button
                  size="icon-sm"
                  variant={isOpen && open.panel === 'history' ? 'secondary' : 'ghost'}
                  title={t.data.history}
                  aria-label={t.data.history}
                  onClick={() => toggle(product.id, 'history')}
                >
                  <History />
                </Button>
                <Button
                  size="icon-sm"
                  variant={isOpen && open.panel === 'edit' ? 'secondary' : 'ghost'}
                  title={t.data.edit}
                  aria-label={t.data.edit}
                  onClick={() => toggle(product.id, 'edit')}
                >
                  <Pencil />
                </Button>
                <Button
                  size="icon-sm"
                  variant="ghost"
                  className="text-destructive"
                  title={t.common.delete}
                  aria-label={t.common.delete}
                  disabled={pending}
                  onClick={() => window.confirm(t.data.deleteFoodConfirm(product.name)) && run(() => deleteFoodAction(product.id, product.name))}
                >
                  <Trash2 />
                </Button>
              </div>
            </div>
            {isOpen && open.panel === 'edit' && (
              <div className="grid gap-6 border-t bg-muted/30 px-4 py-4 lg:grid-cols-2">
                <InfoEditor product={product} pending={pending} onSave={(form) => run(() => updateFoodAction(product.id, form))} />
                <NutritionEditor
                  basis={active?.basis ?? null}
                  pending={pending}
                  onSave={(form) => run(() => addFoodVersionAction(product.id, product.activeVersionId, form))}
                />
              </div>
            )}
            {isOpen && open.panel === 'history' && <VersionHistory versions={product.versions} />}
          </div>
        )
      })}
    </div>
  )
}

function Field({ label, children, hint }: { label: string; children: React.ReactNode; hint?: string }) {
  return (
    <div className="flex flex-col gap-1.5">
      <Label className="text-xs text-muted-foreground">{label}</Label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

function UnitSelect({ value, onChange }: { value: 'g' | 'ml'; onChange: (unit: 'g' | 'ml') => void }) {
  return (
    <div className="flex shrink-0 rounded-md border p-0.5">
      {(['g', 'ml'] as const).map((unit) => (
        <button
          key={unit}
          type="button"
          onClick={() => onChange(unit)}
          className={cn('rounded px-2.5 py-1 text-xs', value === unit ? 'bg-primary text-primary-foreground' : 'text-muted-foreground')}
        >
          {unit}
        </button>
      ))}
    </div>
  )
}

/** 名称、品牌、叫法、净含量、备注：直接改，不产生新版本。 */
function InfoEditor({ product, pending, onSave }: { product: FoodRow; pending: boolean; onSave: (form: FoodInfoForm) => void }) {
  const t = useT()
  const [form, setForm] = useState<FoodInfoForm>({
    name: product.name,
    brand: product.brand ?? '',
    aliases: product.aliases.join('、'),
    packageAmount: product.package ? String(product.package.amount) : '',
    packageUnit: product.package?.unit ?? 'g',
    note: product.note ?? '',
  })
  const set = (patch: Partial<FoodInfoForm>) => setForm({ ...form, ...patch })
  return (
    <div className="flex flex-col gap-3">
      <div>
        <h3 className="font-medium">{t.data.infoTitle}</h3>
        <p className="text-xs text-muted-foreground">{t.data.infoHint}</p>
      </div>
      <Field label={t.data.name}>
        <Input value={form.name} onChange={(event) => set({ name: event.target.value })} />
      </Field>
      <Field label={t.data.brand}>
        <Input value={form.brand} onChange={(event) => set({ brand: event.target.value })} />
      </Field>
      <Field label={t.data.aliases} hint={t.data.aliasesPlaceholder}>
        <Input value={form.aliases} onChange={(event) => set({ aliases: event.target.value })} />
      </Field>
      <Field label={t.data.packageLabel} hint={t.data.packageHint}>
        <div className="flex items-center gap-2">
          <Input inputMode="decimal" value={form.packageAmount} onChange={(event) => set({ packageAmount: event.target.value })} />
          <UnitSelect value={form.packageUnit} onChange={(packageUnit) => set({ packageUnit })} />
        </div>
      </Field>
      <Field label={t.data.note}>
        <Input value={form.note} onChange={(event) => set({ note: event.target.value })} />
      </Field>
      <Button className="self-start" disabled={pending} onClick={() => onSave(form)}>
        {t.data.save}
      </Button>
    </div>
  )
}

/** 营养值：保存为新版本并生效；旧版本留在历史里，已经记下的饮食不变。 */
function NutritionEditor({ basis, pending, onSave }: { basis: FoodVersionBasis | null; pending: boolean; onSave: (form: FoodNutritionForm) => void }) {
  const t = useT()
  const n = basis?.nutrients
  const text = (value: number | undefined) => (value === undefined ? '' : String(value))
  const [form, setForm] = useState<FoodNutritionForm>({
    basisAmount: basis ? String(basis.quantity.amount) : '100',
    basisUnit: basis?.quantity.unit ?? 'g',
    energyKcal: text(n?.energyKcal),
    proteinG: text(n?.proteinG),
    fatG: text(n?.fatG),
    carbohydrateG: text(n?.carbohydrateG),
    sodiumMg: text(n?.sodiumMg),
    saturatedFatG: text(n?.saturatedFatG),
    sugarG: text(n?.sugarG),
    sourceNote: '',
  })
  const set = (patch: Partial<FoodNutritionForm>) => setForm({ ...form, ...patch })
  const numberField = (key: keyof FoodNutritionForm, label: string, unit: string) => (
    <Field label={`${label}（${unit}）`}>
      <Input inputMode="decimal" value={form[key] as string} onChange={(event) => set({ [key]: event.target.value })} />
    </Field>
  )
  return (
    <div className="flex flex-col gap-3">
      <div>
        <h3 className="font-medium">{t.data.nutritionTitle}</h3>
        <p className="text-xs text-muted-foreground">{t.data.nutritionHint}</p>
      </div>
      <Field label={t.data.basis}>
        <div className="flex items-center gap-2">
          <Input inputMode="decimal" value={form.basisAmount} onChange={(event) => set({ basisAmount: event.target.value })} />
          <UnitSelect value={form.basisUnit} onChange={(basisUnit) => set({ basisUnit })} />
        </div>
      </Field>
      <div className="grid grid-cols-2 gap-3">
        {numberField('energyKcal', t.data.energy, 'kcal')}
        {numberField('proteinG', t.data.protein, 'g')}
        {numberField('fatG', t.data.fat, 'g')}
        {numberField('carbohydrateG', t.data.carbohydrate, 'g')}
      </div>
      <p className="text-xs text-muted-foreground">{t.data.extrasHint}</p>
      <div className="grid grid-cols-3 gap-3">
        {numberField('sodiumMg', t.data.sodium, 'mg')}
        {numberField('saturatedFatG', t.data.saturatedFat, 'g')}
        {numberField('sugarG', t.data.sugar, 'g')}
      </div>
      <Field label={t.data.versionNote}>
        <Input value={form.sourceNote} placeholder={t.data.manualVersionNote} onChange={(event) => set({ sourceNote: event.target.value })} />
      </Field>
      <Button className="self-start" disabled={pending} onClick={() => onSave(form)}>
        {t.data.saveAsVersion}
      </Button>
    </div>
  )
}

function VersionHistory({ versions }: { versions: VersionRow[] }) {
  const t = useT()
  return (
    <div className="flex flex-col gap-2 border-t bg-muted/30 px-4 py-3">
      {versions.map((version) => (
        <details key={version.id} open={version.active} className="rounded-md border bg-background px-3 py-2">
          <summary className="flex cursor-pointer list-none items-center gap-2">
            <ChevronDown className="size-3.5 text-muted-foreground" />
            <span className="tabular-nums">{version.createdAt}</span>
            {version.active ? <Badge>{t.data.activeVersion}</Badge> : <Badge variant="outline">{t.data.oldVersion}</Badge>}
            <span className="text-xs text-muted-foreground">{t.data.sourceKinds[version.source]}</span>
          </summary>
          <div className="mt-2 text-xs text-muted-foreground tabular-nums">
            {t.data.perBasis(`${version.basis.quantity.amount} ${version.basis.quantity.unit}`)}：{nutrientsText(version.basis)}
            {version.sourceNote && <div className="mt-1">{version.sourceNote}</div>}
          </div>
        </details>
      ))}
    </div>
  )
}
