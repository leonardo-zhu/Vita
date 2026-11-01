'use client'

import { useState } from 'react'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useT } from '@/i18n/client'
import { formatTime } from '@/lib/format'
import type { EventRow } from '@/server/diagnostics/query'

const PAGE_SIZE = 20

/** 最近的事件，前端分页。筛选条件变了，页面会带着新数据重新挂载，回到第一页 */
export function EventsTable({ events }: { events: EventRow[] }) {
  const t = useT()
  const [page, setPage] = useState(0)
  const pages = Math.max(1, Math.ceil(events.length / PAGE_SIZE))
  const current = Math.min(page, pages - 1)
  const rows = events.slice(current * PAGE_SIZE, (current + 1) * PAGE_SIZE)

  if (events.length === 0) return <p className="text-sm text-muted-foreground">{t.common.noData}</p>

  return (
    <div className="flex flex-col gap-3">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t.diagnostics.time}</TableHead>
            <TableHead>{t.diagnostics.type}</TableHead>
            <TableHead>{t.diagnostics.result}</TableHead>
            <TableHead className="text-right">{t.diagnostics.latency}</TableHead>
            <TableHead>{t.diagnostics.config}</TableHead>
            <TableHead>{t.diagnostics.request}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((event) => {
            const result =
              event.event_type === 'tool_call'
                ? `${event.tool} → ${event.result_code}`
                : [event.outcome, event.error_code].filter(Boolean).join(' · ')
            const failed =
              event.outcome === 'error' || event.outcome === 'failed' || (event.result_code !== null && event.result_code !== 'ok')
            return (
              <TableRow key={event.id}>
                <TableCell className="whitespace-nowrap">{formatTime(event.occurred_at)}</TableCell>
                <TableCell>{t.diagnostics.types[event.event_type] ?? event.event_type}</TableCell>
                <TableCell className={failed ? 'font-mono text-xs text-destructive' : 'font-mono text-xs'}>
                  {result}
                  {event.claimed_card_without_tool === 1 && (
                    <Badge className="ml-2" variant="destructive">
                      {t.diagnostics.claimedBadge}
                    </Badge>
                  )}
                </TableCell>
                <TableCell className="text-right whitespace-nowrap">{event.latency_ms} ms</TableCell>
                <TableCell className="font-mono text-xs">{event.config_version ?? t.common.builtin}</TableCell>
                <TableCell className="font-mono text-xs text-muted-foreground">
                  {event.request_id?.slice(0, 8) ?? t.common.none}
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
      {pages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm">
          <span className="text-muted-foreground tabular-nums">{t.common.page(current + 1, pages)}</span>
          <Button variant="outline" size="sm" disabled={current === 0} onClick={() => setPage(current - 1)}>
            {t.common.prev}
          </Button>
          <Button variant="outline" size="sm" disabled={current >= pages - 1} onClick={() => setPage(current + 1)}>
            {t.common.next}
          </Button>
        </div>
      )}
    </div>
  )
}
