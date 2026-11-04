'use client'

import { Pencil, Trash2 } from 'lucide-react'
import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useT } from '@/i18n/client'

import type { ActionResult } from '../../actions'
import { deleteFoodAction, updateFoodAction } from '../../data-actions'

interface FoodRow {
  id: string
  name: string
  brand: string | null
  aliases: string[]
  packageText: string | null
  basisText: string | null
  nutrients: string | null
  versions: number
  labelScanId: string | null
}

export function FoodList({ products }: { products: FoodRow[] }) {
  const t = useT()
  const [pending, startTransition] = useTransition()
  const [editing, setEditing] = useState<{ id: string; name: string; brand: string; aliases: string } | null>(null)

  function run(action: () => Promise<ActionResult>, after?: () => void) {
    startTransition(async () => {
      const result = await action()
      if (result.ok) {
        toast.success(result.message ?? t.data.saved)
        after?.()
      } else toast.error(result.message)
    })
  }

  return (
    <div className="flex flex-col gap-3">
      {products.map((product) => (
        <div key={product.id} className="flex flex-wrap items-start gap-3 rounded-lg border px-3 py-2 text-sm">
          {product.labelScanId && (
            <a href={`/admin/labels/${product.labelScanId}`} target="_blank" rel="noreferrer" className="shrink-0">
              {/* eslint-disable-next-line @next/next/no-img-element -- 经 Admin 转发的私有照片 */}
              <img src={`/admin/labels/${product.labelScanId}`} alt={t.data.labelPhoto} className="h-16 w-16 rounded border object-cover" />
            </a>
          )}
          {editing?.id === product.id ? (
            <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">
              <Input aria-label={t.data.name} value={editing.name} onChange={(event) => setEditing({ ...editing, name: event.target.value })} className="w-48" />
              <Input
                aria-label={t.data.brand}
                placeholder={t.data.brand}
                value={editing.brand}
                onChange={(event) => setEditing({ ...editing, brand: event.target.value })}
                className="w-36"
              />
              <Input
                aria-label={t.data.aliases}
                placeholder={t.data.aliasesPlaceholder}
                value={editing.aliases}
                onChange={(event) => setEditing({ ...editing, aliases: event.target.value })}
                className="w-56"
              />
              <Button
                size="sm"
                disabled={pending}
                onClick={() => run(() => updateFoodAction(product.id, editing.name, editing.brand, editing.aliases), () => setEditing(null))}
              >
                {t.data.save}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>
                {t.common.cancel}
              </Button>
            </div>
          ) : (
            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
              <span className="font-medium">
                {product.name}
                {product.brand && <span className="ml-2 text-xs font-normal text-muted-foreground">{product.brand}</span>}
              </span>
              {product.aliases.length > 0 && <span className="text-xs text-muted-foreground">{t.data.alsoCalled(product.aliases.join('、'))}</span>}
              {product.nutrients && (
                <span className="text-xs text-muted-foreground tabular-nums">
                  {t.data.perBasis(product.basisText ?? '')}：{product.nutrients}
                </span>
              )}
              <span className="text-xs text-muted-foreground">
                {[product.packageText, t.data.versions(product.versions)].filter(Boolean).join(' · ')}
              </span>
            </div>
          )}
          {editing?.id !== product.id && (
            <div className="flex gap-1">
              <Button
                size="icon-sm"
                variant="ghost"
                title={t.data.edit}
                aria-label={t.data.edit}
                disabled={pending}
                onClick={() => setEditing({ id: product.id, name: product.name, brand: product.brand ?? '', aliases: product.aliases.join('、') })}
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
          )}
        </div>
      ))}
    </div>
  )
}
