'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { useT } from '@/i18n/client'
import type { Messages } from '@/i18n/messages'
import { formatTime } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { TrialRun } from '@/server/trial'

import { runTrialAction, type TrialMode } from '../../actions'

interface Props {
  configured: boolean
  liveVersion: string | null
  draftDirty: boolean
  defaultContext: string
  history: TrialRun[]
}

export function Playground({ configured, liveVersion, draftDirty, defaultContext, history }: Props) {
  const t = useT()
  const [mode, setMode] = useState<TrialMode>(draftDirty ? 'both' : 'live')
  const [message, setMessage] = useState('')
  const [context, setContext] = useState(defaultContext)
  const [runs, setRuns] = useState<TrialRun[] | null>(null)
  const [pending, startTransition] = useTransition()

  function run() {
    startTransition(async () => {
      const result = await runTrialAction({ mode, message, context })
      if (!result.ok) {
        toast.error(result.message)
        return
      }
      setRuns(result.runs)
    })
  }

  const modes: { value: TrialMode; label: string }[] = [
    { value: 'live', label: t.playground.live(liveVersion) },
    { value: 'draft', label: t.playground.draft },
    { value: 'both', label: t.playground.both },
  ]

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">{t.playground.title}</h1>
        <p className="text-sm text-muted-foreground">{t.playground.description}</p>
      </div>

      {!configured && (
        <Alert>
          <AlertTitle>{t.playground.notConfiguredTitle}</AlertTitle>
          <AlertDescription>{t.playground.notConfiguredBody}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardContent className="flex flex-col gap-4">
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-sm font-medium">{t.playground.which}</legend>
            <div className="flex flex-wrap gap-2">
              {modes.map((option) => (
                <label
                  key={option.value}
                  className={cn(
                    'cursor-pointer rounded-lg border px-3 py-1.5 text-sm transition-colors has-focus-visible:ring-3 has-focus-visible:ring-ring/50',
                    mode === option.value ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted'
                  )}
                >
                  <input
                    type="radio"
                    name="mode"
                    value={option.value}
                    checked={mode === option.value}
                    onChange={() => setMode(option.value)}
                    className="sr-only"
                  />
                  {option.label}
                </label>
              ))}
            </div>
          </fieldset>
          <Label className="flex flex-col items-stretch gap-1.5">
            <span>{t.playground.message}</span>
            <Textarea
              rows={3}
              value={message}
              placeholder={t.playground.messagePlaceholder}
              onChange={(e) => setMessage(e.target.value)}
            />
          </Label>
          <details>
            <summary className="cursor-pointer text-sm text-muted-foreground">{t.playground.context}</summary>
            <Textarea
              aria-label={t.playground.contextLabel}
              rows={8}
              className="mt-2 font-mono text-xs"
              value={context}
              onChange={(e) => setContext(e.target.value)}
            />
          </details>
          <div className="flex justify-end">
            <Button disabled={!configured || pending || !message.trim()} onClick={run}>
              {pending ? t.playground.running : t.playground.run}
            </Button>
          </div>
        </CardContent>
      </Card>

      {runs && (
        <div className={cn('grid gap-4', runs.length > 1 && 'lg:grid-cols-2')}>
          {[...runs].sort((a, b) => (a.source === 'live' ? -1 : b.source === 'live' ? 1 : 0)).map((run) => (
            <RunCard key={run.id} run={run} />
          ))}
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle>{t.playground.recentTitle}</CardTitle>
          <CardDescription>{t.playground.recentDescription}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {history.length === 0 && <p className="text-sm text-muted-foreground">{t.playground.none}</p>}
          {history.map((run) => (
            <details key={run.id} className="rounded-lg border px-3 py-2">
              <summary className="flex cursor-pointer list-none flex-wrap items-center gap-2 text-sm">
                <span className="text-muted-foreground">{formatTime(run.createdAt)}</span>
                <SourceBadge run={run} />
                <span className="min-w-0 flex-1 truncate">{run.message}</span>
                {run.error ? (
                  <Badge variant="destructive">{t.playground.failed}</Badge>
                ) : (
                  run.output?.toolCalls.map((call, i) => (
                    <Badge key={i} variant="outline" className="font-mono">
                      {call.name}
                    </Badge>
                  ))
                )}
              </summary>
              <div className="pt-3">
                <RunBody run={run} />
              </div>
            </details>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}

function SourceBadge({ run }: { run: TrialRun }) {
  const t = useT()
  if (run.source === 'draft') return <Badge>{t.playground.draftShort}</Badge>
  return <Badge variant="secondary">{t.playground.liveShort(run.configVersion)}</Badge>
}

function RunCard({ run }: { run: TrialRun }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <SourceBadge run={run} />
          <span className="font-mono text-sm font-normal text-muted-foreground">{run.model}</span>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <RunBody run={run} />
      </CardContent>
    </Card>
  )
}

function RunBody({ run }: { run: TrialRun }) {
  const t = useT()
  return (
    <div className="flex flex-col gap-3 text-sm">
      {run.error && <p className="text-destructive">{errorText(t, run.error)}</p>}
      {run.output?.reasoning && (
        <details>
          <summary className="cursor-pointer text-muted-foreground">{t.playground.reasoning}</summary>
          <p className="mt-1 whitespace-pre-wrap text-muted-foreground">{run.output.reasoning}</p>
        </details>
      )}
      {run.output?.text && <p className="whitespace-pre-wrap">{run.output.text}</p>}
      {run.output?.toolCalls.map((call, i) => (
        <div key={i} className="flex flex-col gap-1">
          <span className="text-xs text-muted-foreground">
            {t.playground.callsTool} <span className="font-mono text-foreground">{call.name}</span>
          </span>
          <pre className="max-h-80 overflow-auto rounded-lg bg-muted p-3 text-xs">{prettyJSON(call.arguments)}</pre>
        </div>
      ))}
      {run.output && !run.output.text && run.output.toolCalls.length === 0 && (
        <p className="text-muted-foreground">{t.playground.noOutput}</p>
      )}
      <p className="font-mono text-xs text-muted-foreground">
        {t.common.seconds((run.latencyMs / 1000).toFixed(1))}
        {run.inputTokens !== null && ` · ${t.playground.tokens(run.inputTokens, run.outputTokens)}`} ·{' '}
        {t.playground.request(run.requestId)}
      </p>
    </div>
  )
}

function errorText(t: Messages, error: string): string {
  return error === 'timeout' ? t.playground.timeout : error
}

function prettyJSON(text: string): string {
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}
