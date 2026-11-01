'use client'

import { useRouter } from 'next/navigation'
import { useState } from 'react'

import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { useT } from '@/i18n/client'

export interface CompareOption {
  value: string
  label: string
}

/** 选两个版本跳到对比页；空值表示用对比页的默认选择 */
export function CompareForm({ options, from, to }: { options: CompareOption[]; from: string; to: string }) {
  const t = useT()
  const router = useRouter()
  const [left, setLeft] = useState(from)
  const [right, setRight] = useState(to)
  const select =
    'h-8 rounded-lg border border-input bg-background px-2 text-sm outline-none focus-visible:ring-3 focus-visible:ring-ring/50'

  return (
    <form
      className="flex flex-wrap items-end gap-3"
      onSubmit={(event) => {
        event.preventDefault()
        const query = new URLSearchParams()
        if (left) query.set('from', left)
        if (right) query.set('to', right)
        router.push(`/admin/releases/compare?${query}`)
      }}
    >
      <Label className="flex flex-col items-start gap-1.5">
        <span>{t.compare.from}</span>
        <select className={select} value={left} onChange={(e) => setLeft(e.target.value)}>
          <option value="">{t.compare.previous}</option>
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </Label>
      <Label className="flex flex-col items-start gap-1.5">
        <span>{t.compare.to}</span>
        <select className={select} value={right} onChange={(e) => setRight(e.target.value)}>
          <option value="">{t.compare.liveDefault}</option>
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </Label>
      <Button type="submit" variant="outline">
        {t.compare.submit}
      </Button>
    </form>
  )
}
