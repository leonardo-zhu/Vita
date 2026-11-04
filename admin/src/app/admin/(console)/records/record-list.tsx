'use client'

import { Pencil, Trash2 } from 'lucide-react'
import { useTransition } from 'react'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { useT } from '@/i18n/client'

import type { ActionResult } from '../../actions'
import { deleteItemAction, deleteRecordAction, rescaleItemAction } from '../../data-actions'

interface ItemRow {
  id: string
  name: string
  amount: string
  unit: 'g' | 'ml' | null
  quantity: number | null
  source: string
  energy: number
  protein: string
}

interface RecordRow {
  id: string
  title: string
  energy: number
  items: ItemRow[]
}

export function RecordList({ date, revision, records }: { date: string; revision: number; records: RecordRow[] }) {
  const t = useT()
  const [pending, startTransition] = useTransition()

  function run(action: () => Promise<ActionResult>) {
    startTransition(async () => {
      const result = await action()
      if (result.ok) toast.success(result.message ?? t.data.saved)
      else toast.error(result.message)
    })
  }

  function deleteRecord(record: RecordRow) {
    if (!window.confirm(t.data.deleteRecordConfirm)) return
    run(() => deleteRecordAction(date, revision, record.id))
  }

  function deleteItem(record: RecordRow, item: ItemRow) {
    if (!window.confirm(t.data.deleteItemConfirm(item.name))) return
    // 最后一项：删掉它就是删掉整条记录。
    run(() => (record.items.length === 1 ? deleteRecordAction(date, revision, record.id) : deleteItemAction(date, revision, record.id, item.id)))
  }

  function rescale(record: RecordRow, item: ItemRow) {
    const input = window.prompt(t.data.rescalePrompt(item.amount, item.unit), item.quantity === null ? '1' : String(item.quantity))
    if (input === null) return
    const value = Number(input.trim())
    if (!Number.isFinite(value) || value <= 0) {
      toast.error(t.data.badAmount)
      return
    }
    const change = item.unit && item.quantity !== null ? { quantity: { amount: value, unit: item.unit } } : { factor: value }
    run(() => rescaleItemAction(date, revision, record.id, item.id, change))
  }

  return (
    <div className="flex flex-col gap-4">
      {records.map((record) => (
        <Card key={record.id}>
          <CardHeader className="flex flex-row items-center justify-between gap-2">
            <CardTitle className="text-base">
              {record.title || '—'} <span className="text-sm font-normal text-muted-foreground">{record.energy} kcal</span>
            </CardTitle>
            <Button size="sm" variant="outline" className="text-destructive" disabled={pending} onClick={() => deleteRecord(record)}>
              <Trash2 />
              {t.data.deleteRecord}
            </Button>
          </CardHeader>
          <CardContent className="flex flex-col gap-2">
            {record.items.map((item) => (
              <div key={item.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border px-3 py-2 text-sm">
                <div className="flex min-w-0 flex-1 flex-col">
                  <span className="font-medium">{item.name}</span>
                  <span className="text-xs text-muted-foreground">
                    {item.amount} · {item.source}
                  </span>
                </div>
                <span className="text-xs tabular-nums">
                  {item.energy} kcal · P {item.protein} g
                </span>
                <div className="flex">
                  <Button size="icon-sm" variant="ghost" title={t.data.rescale} aria-label={t.data.rescale} disabled={pending} onClick={() => rescale(record, item)}>
                    <Pencil />
                  </Button>
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-destructive"
                    title={t.common.delete}
                    aria-label={t.common.delete}
                    disabled={pending}
                    onClick={() => deleteItem(record, item)}
                  >
                    <Trash2 />
                  </Button>
                </div>
              </div>
            ))}
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
