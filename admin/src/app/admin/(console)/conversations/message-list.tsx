'use client'

import { EyeOff, ListEnd, MessagesSquare, MoreHorizontal, RotateCcw, Ticket } from 'lucide-react'
import { useTransition } from 'react'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
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

/** 和 App 一样的对话气泡：用户在右，Vita 在左。排除的消息变淡、虚线框，操作收进右上角的菜单。 */
export function MessageList({ messages }: { messages: MessageRow[] }) {
  const t = useT()
  const [pending, startTransition] = useTransition()

  function set(ids: string[], excluded: boolean, confirmText?: string) {
    const targets = ids.filter((id) => messages.find((message) => message.id === id)?.excluded !== excluded)
    if (targets.length === 0) return
    if (confirmText && !window.confirm(confirmText)) return
    startTransition(async () => {
      for (const id of targets) {
        const result = await setMessageExcludedAction(id, excluded)
        if (!result.ok) {
          toast.error(result.message)
          return
        }
      }
      toast.success(t.data.saved)
    })
  }

  /** 一问一答：用户的话和紧跟着的 Vita 回复。 */
  function turn(index: number): string[] {
    const message = messages[index]
    if (message.role === 'user') return [message.id, ...(messages[index + 1]?.role === 'assistant' ? [messages[index + 1].id] : [])]
    return [...(messages[index - 1]?.role === 'user' ? [messages[index - 1].id] : []), message.id]
  }

  return (
    <div className="flex flex-col gap-4">
      {messages.map((message, index) => {
        const mine = message.role === 'user'
        return (
          <div key={message.id} className={cn('group flex flex-col gap-1', mine ? 'items-end' : 'items-start')}>
            <div className={cn('flex items-center gap-1.5 px-1 text-xs text-muted-foreground', mine && 'flex-row-reverse')}>
              <span className="font-medium">{mine ? t.data.user : t.data.assistant}</span>
              <span>{message.time}</span>
              {message.hasCard && (
                <span className="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-primary">
                  <Ticket className="size-3" />
                  {t.data.card('')}
                </span>
              )}
              {message.excluded && (
                <span className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5">
                  <EyeOff className="size-3" />
                  {t.data.excluded}
                </span>
              )}
              <DropdownMenu modal={false}>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={t.data.actions}
                      disabled={pending}
                      className="opacity-60 transition-opacity group-hover:opacity-100"
                    />
                  }
                >
                  <MoreHorizontal />
                </DropdownMenuTrigger>
                <DropdownMenuContent align={mine ? 'end' : 'start'}>
                  {message.excluded ? (
                    <>
                      <DropdownMenuItem onClick={() => set([message.id], false)}>
                        <RotateCcw />
                        {t.data.include}
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => set(turn(index), false)}>
                        <MessagesSquare />
                        {t.data.includeTurn}
                      </DropdownMenuItem>
                    </>
                  ) : (
                    <>
                      <DropdownMenuItem onClick={() => set(turn(index), true)}>
                        <MessagesSquare />
                        {t.data.excludeTurn}
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => set([message.id], true)}>
                        <EyeOff />
                        {t.data.exclude}
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      <DropdownMenuItem
                        variant="destructive"
                        onClick={() => {
                          const ids = messages.slice(index).map((item) => item.id)
                          set(ids, true, t.data.excludeFromConfirm(ids.filter((id) => !messages.find((item) => item.id === id)?.excluded).length))
                        }}
                      >
                        <ListEnd />
                        {t.data.excludeFrom}
                      </DropdownMenuItem>
                    </>
                  )}
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
            <div
              className={cn(
                'flex max-w-[85%] flex-col gap-2 rounded-2xl px-4 py-2.5 text-sm sm:max-w-[75%]',
                mine ? 'rounded-tr-sm bg-primary text-primary-foreground' : 'rounded-tl-sm bg-muted',
                message.excluded && 'border border-dashed border-muted-foreground/40 bg-transparent text-muted-foreground opacity-60'
              )}
            >
              {message.labelScanIds.length > 0 && (
                <div className={cn('flex flex-wrap gap-2', mine && 'justify-end')}>
                  {message.labelScanIds.map((id) => (
                    <a key={id} href={`/admin/labels/${id}`} target="_blank" rel="noreferrer">
                      {/* eslint-disable-next-line @next/next/no-img-element -- 经 Admin 转发的私有照片，不走 next/image */}
                      <img src={`/admin/labels/${id}`} alt={t.data.labelPhoto} className="h-28 w-auto rounded-lg object-cover" />
                    </a>
                  ))}
                </div>
              )}
              {message.text && <p className="leading-relaxed whitespace-pre-wrap">{message.text}</p>}
            </div>
          </div>
        )
      })}
    </div>
  )
}
