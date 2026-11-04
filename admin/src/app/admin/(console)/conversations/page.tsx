import Link from 'next/link'

import { DateForm } from '@/components/admin/date-form'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { clock, isLocalDate, todayInShanghai } from '@/lib/dates'
import { cn } from '@/lib/utils'
import { conversationDays, dayMessages, dayTraces, vitaApiConfigured } from '@/server/vita-api'

import { MessageList } from './message-list'

export const generateMetadata = titled('conversations')

export default async function ConversationsPage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const t = await getT()
  if (!vitaApiConfigured()) {
    return (
      <Alert>
        <AlertTitle>{t.devices.notConfiguredTitle}</AlertTitle>
        <AlertDescription>{t.devices.notConfiguredBody}</AlertDescription>
      </Alert>
    )
  }
  const requested = (await searchParams).date
  let data: { days: Awaited<ReturnType<typeof conversationDays>>; messages: Awaited<ReturnType<typeof dayMessages>>; traces: Awaited<ReturnType<typeof dayTraces>> }
  let date: string
  try {
    const days = await conversationDays()
    date = isLocalDate(requested) ? requested : (days[0]?.date ?? todayInShanghai())
    const [messages, traces] = await Promise.all([dayMessages(date), dayTraces(date)])
    data = { days, messages, traces }
  } catch (error) {
    return <p className="text-sm text-destructive">{t.data.loadFailed((error as Error).message)}</p>
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold">{t.data.conversationsTitle}</h1>
        <DateForm date={date} label={t.data.pickDate} submit={t.data.go} />
      </div>
      <p className="text-sm text-muted-foreground">{t.data.conversationsDescription}</p>

      <div className="flex gap-2 overflow-x-auto pb-1 [scrollbar-width:thin]">
        {data.days.length === 0 && <span className="text-sm text-muted-foreground">{t.data.noDays}</span>}
        {data.days.slice(0, 30).map((day) => (
          <Link
            key={day.date}
            href={`/admin/conversations?date=${day.date}`}
            className={cn(
              'flex shrink-0 flex-col rounded-md border px-3 py-1.5 text-xs',
              day.date === date ? 'border-primary bg-primary/5' : 'text-muted-foreground hover:text-foreground'
            )}
          >
            <span className="font-medium">{day.date.slice(5)}</span>
            <span>{t.data.dayCount(day.messages, day.excluded)}</span>
          </Link>
        ))}
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{date}</CardTitle>
        </CardHeader>
        <CardContent>
          {data.messages.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t.data.noMessages}</p>
          ) : (
            <MessageList
              messages={data.messages.map((message) => ({
                id: message.id,
                role: message.role,
                text: message.text,
                time: clock(message.createdAt),
                labelScanIds: message.labelScanIds,
                hasCard: message.cardRef?.type === 'pending',
                excluded: message.excludedFromContext,
              }))}
            />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t.data.traces}</CardTitle>
          <CardDescription>{t.data.tracesDescription}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {data.traces.length === 0 && <p className="text-sm text-muted-foreground">{t.data.noTraces}</p>}
          {data.traces.map((trace) => (
            <details key={trace.requestId} className="rounded-lg border px-3 py-2 text-sm">
              <summary className="flex cursor-pointer flex-wrap items-center gap-2">
                <span className="text-muted-foreground">{clock(trace.createdAt)}</span>
                {trace.kind === 'continuation' && <Badge variant="secondary">{t.data.continuation}</Badge>}
                {trace.outcome !== 'ok' && <Badge variant="destructive">{trace.errorCode ?? trace.outcome}</Badge>}
                {trace.pendingId && <Badge>{t.data.card(trace.pendingId.slice(0, 8))}</Badge>}
                <span className="min-w-0 flex-1 truncate">{trace.inputText || '—'}</span>
                <span className="text-xs text-muted-foreground">
                  {t.data.traceMeta(trace.rounds, trace.tokensIn?.toLocaleString() ?? '—', t.common.seconds((trace.latencyMs / 1000).toFixed(1)))}
                </span>
              </summary>
              <div className="mt-3 flex flex-col gap-3">
                <div className="text-xs text-muted-foreground">
                  {trace.model} · {trace.configVersion}
                </div>
                {trace.reply && <p className="whitespace-pre-wrap">{trace.reply}</p>}
                <div>
                  <div className="mb-1 font-medium">{t.data.steps}</div>
                  {trace.steps.length === 0 && <p className="text-muted-foreground">{t.data.noSteps}</p>}
                  {trace.steps.map((step, index) => (
                    <details key={index} className="mb-1 rounded border px-2 py-1">
                      <summary className="cursor-pointer">
                        {step.tool} <span className={step.resultCode === 'ok' ? 'text-muted-foreground' : 'text-destructive'}>· {step.resultCode}</span>
                      </summary>
                      <pre className="mt-1 overflow-x-auto text-xs whitespace-pre-wrap">{step.arguments}</pre>
                      <pre className="mt-1 overflow-x-auto text-xs whitespace-pre-wrap text-muted-foreground">{step.output}</pre>
                    </details>
                  ))}
                </div>
                {trace.reasoning && (
                  <details>
                    <summary className="cursor-pointer font-medium">{t.data.reasoning}</summary>
                    <p className="mt-1 text-xs whitespace-pre-wrap text-muted-foreground">{trace.reasoning}</p>
                  </details>
                )}
              </div>
            </details>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}
