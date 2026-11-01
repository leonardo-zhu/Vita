import { titled } from '@/i18n/metadata'
import Link from 'next/link'

import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import type { Messages } from '@/i18n/messages'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { RETENTION_DAYS } from '@/server/diagnostics/ingest'
import {
  filterOptions,
  listInstalls,
  recentEvents,
  summary,
  type ChatSummary,
  type DiagnosticsFilter,
} from '@/server/diagnostics/query'

import { EventsTable } from './events-table'
import { DiagnosticsFilters } from './filters'
import { InstallActions } from './install-actions'

export const generateMetadata = titled('diagnostics')

const EVENT_LIMIT = 500

function seconds(t: Messages, ms: number | null) {
  return ms === null ? t.common.none : t.common.seconds((ms / 1000).toFixed(1))
}

function rate(part: number, total: number) {
  return total ? `${((part / total) * 100).toFixed(1)}%` : '—'
}

export default async function DiagnosticsPage({
  searchParams,
}: {
  searchParams: Promise<{ days?: string; config?: string; app?: string; code?: string }>
}) {
  const params = await searchParams
  const t = await getT()
  const filter: DiagnosticsFilter = {
    days: [1, 7, 30].includes(Number(params.days)) ? Number(params.days) : 7,
    configVersion: params.config || undefined,
    appVersion: params.app || undefined,
    errorCode: params.code || undefined,
  }
  const data = summary(filter)
  const events = recentEvents(filter, EVENT_LIMIT)
  const chat = data.chat

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">{t.diagnostics.title}</h1>
        <p className="text-sm text-muted-foreground">{t.diagnostics.description(RETENTION_DAYS)}</p>
      </div>

      <DiagnosticsFilters
        days={filter.days}
        config={filter.configVersion ?? ''}
        app={filter.appVersion ?? ''}
        code={filter.errorCode ?? ''}
        options={filterOptions()}
      />

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label={t.diagnostics.turns} value={String(chat.count)} hint={t.diagnostics.installs(data.installs)} />
        <Stat
          label={t.diagnostics.failureRate}
          value={rate(chat.errors, chat.count)}
          hint={t.diagnostics.failures(chat.errors, chat.cancelled)}
        />
        <Stat label={t.diagnostics.okLatency} value={seconds(t, chat.p50)} hint={t.diagnostics.p95(seconds(t, chat.p95))} />
        <Stat
          label={t.diagnostics.claimedCard}
          value={String(chat.claimedCardWithoutTool)}
          hint={t.diagnostics.claimedCardHint(chat.createdPending, chat.hitMaxRounds)}
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t.diagnostics.byVersionTitle}</CardTitle>
          <CardDescription>{t.diagnostics.byVersionDescription}</CardDescription>
        </CardHeader>
        <CardContent>
          {data.byConfigVersion.length === 0 ? (
            <Empty text={t.common.noData} />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t.diagnostics.configVersion}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.turnsColumn}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.failureRate}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.latencyColumn}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.tokensColumn}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.claimedColumn}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.byConfigVersion.map((row: ChatSummary & { configVersion: string }) => (
                  <TableRow key={row.configVersion}>
                    <TableCell className="font-mono">{row.configVersion}</TableCell>
                    <TableCell className="text-right">{row.count}</TableCell>
                    <TableCell className="text-right">{rate(row.errors, row.count)}</TableCell>
                    <TableCell className="text-right">
                      {seconds(t, row.p50)} / {seconds(t, row.p95)}
                    </TableCell>
                    <TableCell className="text-right">
                      {row.avgTokensIn ?? t.common.none} / {row.avgTokensOut ?? t.common.none}
                    </TableCell>
                    <TableCell className="text-right">{row.claimedCardWithoutTool}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t.diagnostics.errorCodesTitle}</CardTitle>
          </CardHeader>
          <CardContent>
            {data.errorCodes.length === 0 ? (
              <Empty text={t.diagnostics.noErrors} />
            ) : (
              <ul className="flex flex-col gap-1.5 text-sm">
                {data.errorCodes.map((row) => (
                  <li key={`${row.type}:${row.code}`} className="flex items-center gap-2">
                    <Link
                      href={`?days=${filter.days}&code=${encodeURIComponent(row.code)}`}
                      className="font-mono underline-offset-4 hover:underline"
                    >
                      {row.code}
                    </Link>
                    <Badge variant="outline">{t.diagnostics.types[row.type] ?? row.type}</Badge>
                    <span className="ml-auto tabular-nums">{row.count}</span>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>{t.diagnostics.configFetchTitle}</CardTitle>
          </CardHeader>
          <CardContent className="flex gap-6 text-sm">
            <span>{t.diagnostics.fetchUpdated(data.configFetch.updated)}</span>
            <span>{t.diagnostics.fetchUnchanged(data.configFetch.unchanged)}</span>
            <span className={data.configFetch.failed ? 'text-destructive' : ''}>
              {t.diagnostics.fetchFailed(data.configFetch.failed)}
            </span>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t.diagnostics.toolsTitle}</CardTitle>
          <CardDescription>{t.diagnostics.toolsDescription}</CardDescription>
        </CardHeader>
        <CardContent>
          {data.tools.length === 0 ? (
            <Empty text={t.common.noData} />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t.diagnostics.tool}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.count}</TableHead>
                  <TableHead className="text-right">{t.diagnostics.failureRate}</TableHead>
                  <TableHead className="text-right">P95</TableHead>
                  <TableHead>{t.diagnostics.codes}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.tools.map((row) => (
                  <TableRow key={row.tool}>
                    <TableCell className="font-mono">{row.tool}</TableCell>
                    <TableCell className="text-right">{row.count}</TableCell>
                    <TableCell className="text-right">{rate(row.failures, row.count)}</TableCell>
                    <TableCell className="text-right">{row.p95 === null ? t.common.none : `${row.p95} ms`}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {Object.entries(row.codes)
                        .map(([code, n]) => `${code} ×${n}`)
                        .join(', ')}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t.diagnostics.eventsTitle}</CardTitle>
          <CardDescription>{t.diagnostics.eventsDescription(EVENT_LIMIT)}</CardDescription>
        </CardHeader>
        <CardContent>
          <EventsTable key={JSON.stringify(filter)} events={events} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t.diagnostics.installsTitle}</CardTitle>
          <CardDescription>{t.diagnostics.installsDescription(RETENTION_DAYS)}</CardDescription>
        </CardHeader>
        <CardContent>
          <InstallList t={t} />
        </CardContent>
      </Card>
    </div>
  )
}

function InstallList({ t }: { t: Messages }) {
  const installs = listInstalls()
  if (installs.length === 0) return <Empty text={t.common.noData} />
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>{t.diagnostics.installId}</TableHead>
          <TableHead>{t.diagnostics.appOs}</TableHead>
          <TableHead>{t.diagnostics.seen}</TableHead>
          <TableHead className="text-right">{t.diagnostics.events}</TableHead>
          <TableHead />
        </TableRow>
      </TableHeader>
      <TableBody>
        {installs.map((install) => (
          <TableRow key={install.install_id}>
            <TableCell className="font-mono text-xs">
              {install.install_id.slice(0, 8)}
              {install.revoked === 1 && (
                <Badge className="ml-2" variant="destructive">
                  {t.diagnostics.revoked}
                </Badge>
              )}
            </TableCell>
            <TableCell className="text-xs">
              {install.app_version} / iOS {install.os_version ?? t.common.none}
            </TableCell>
            <TableCell className="text-xs whitespace-nowrap">
              {formatTime(install.first_seen)} / {formatTime(install.last_seen)}
            </TableCell>
            <TableCell className="text-right">{install.events}</TableCell>
            <TableCell className="text-right">
              <InstallActions installId={install.install_id} revoked={install.revoked === 1} />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

function Stat({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <Card size="sm">
      <CardContent className="flex flex-col gap-1">
        <span className="text-xs text-muted-foreground">{label}</span>
        <span className="text-2xl font-semibold tabular-nums">{value}</span>
        <span className="text-xs text-muted-foreground">{hint}</span>
      </CardContent>
    </Card>
  )
}

function Empty({ text }: { text: string }) {
  return <p className="text-sm text-muted-foreground">{text}</p>
}
