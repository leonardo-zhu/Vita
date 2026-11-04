'use client'

import { useTransition } from 'react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useT } from '@/i18n/client'
import { cn } from '@/lib/utils'

import { setMessageExcludedAction } from '../../data-actions'

interface MessageRow {
  id: string
  role: 'user' | 'assistant'
  text: string
  time: string
  labelScanIds: string[]
  hasCard: boolean
  excluded: boolean
}

export function MessageList({ messages }: { messages: MessageRow[] }) {
  const t = useT()
  const [pending, startTransition] = useTransition()

  function set(ids: string[], excluded: boolean) {
    startTransition(async () => {
      for (const id of ids) {
        const result = await setMessageExcludedAction(id, excluded)
        if (!result.ok) {
          toast.error(result.message)
          return
        }
      }
      toast.success(t.data.saved)
    })
  }

  /** rewind：这条和之后的都不再发给模型。 */
  function excludeFrom(index: number) {
    const ids = messages.slice(index).filter((message) => !message.excluded).map((message) => message.id)
    if (ids.length === 0 || !window.confirm(t.data.excludeFromConfirm(ids.length))) return
    set(ids, true)
  }

  return (
    <div className="flex flex-col gap-3">
      {messages.map((message, index) => (
        <div
          key={message.id}
          className={cn(
            'flex flex-col gap-2 rounded-lg border px-3 py-2 text-sm',
            message.role === 'user' && 'bg-muted/40',
            message.excluded && 'opacity-50'
          )}
        >
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span className="font-medium text-foreground">{message.role === 'user' ? t.data.user : t.data.assistant}</span>
            <span>{message.time}</span>
            {message.hasCard && <Badge variant="secondary">{t.data.card('')}</Badge>}
            {message.excluded && <Badge variant="outline">{t.data.excluded}</Badge>}
            <div className="ml-auto flex gap-1">
              {message.excluded ? (
                <Button size="sm" variant="ghost" disabled={pending} onClick={() => set([message.id], false)}>
                  {t.data.include}
                </Button>
              ) : (
                <>
                  <Button size="sm" variant="ghost" disabled={pending} onClick={() => set([message.id], true)}>
                    {t.data.exclude}
                  </Button>
                  <Button size="sm" variant="ghost" disabled={pending} onClick={() => excludeFrom(index)}>
                    {t.data.excludeFrom}
                  </Button>
                </>
              )}
            </div>
          </div>
          {message.labelScanIds.length > 0 && (
            <div className="flex flex-wrap gap-2">
              {message.labelScanIds.map((id) => (
                <a key={id} href={`/admin/labels/${id}`} target="_blank" rel="noreferrer">
                  {/* eslint-disable-next-line @next/next/no-img-element -- 经 Admin 转发的私有照片，不走 next/image */}
                  <img src={`/admin/labels/${id}`} alt={t.data.labelPhoto} className="h-24 w-auto rounded border object-cover" />
                </a>
              ))}
            </div>
          )}
          {message.text && <p className="whitespace-pre-wrap">{message.text}</p>}
        </div>
      ))}
    </div>
  )
}
