import Link from 'next/link'

import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
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

import { DiagnosticsFilters } from './filters'
import { InstallActions } from './install-actions'

export const metadata = { title: '诊断 · Vita Admin' }

const TYPES: Record<string, string> = { chat_turn: '对话', tool_call: '工具', config_fetch: '配置拉取' }

function seconds(ms: number | null) {
  return ms === null ? '—' : `${(ms / 1000).toFixed(1)} 秒`
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
  const filter: DiagnosticsFilter = {
    days: [1, 7, 30].includes(Number(params.days)) ? Number(params.days) : 7,
    configVersion: params.config || undefined,
    appVersion: params.app || undefined,
    errorCode: params.code || undefined,
  }
  const data = summary(filter)
  const events = recentEvents(filter)
  const chat = data.chat

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">诊断日志</h1>
        <p className="text-sm text-muted-foreground">
          App 上报的元数据：错误码、耗时、token 数与版本，不含对话或饮食内容。保留 {RETENTION_DAYS} 天。App 设置里可以关掉上报。
        </p>
      </div>

      <DiagnosticsFilters
        days={filter.days}
        config={filter.configVersion ?? ''}
        app={filter.appVersion ?? ''}
        code={filter.errorCode ?? ''}
        options={filterOptions()}
      />

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="对话轮数" value={String(chat.count)} hint={`${data.installs} 个安装`} />
        <Stat label="失败率" value={rate(chat.errors, chat.count)} hint={`${chat.errors} 次失败，${chat.cancelled} 次取消`} />
        <Stat label="成功轮耗时" value={seconds(chat.p50)} hint={`P95 ${seconds(chat.p95)}`} />
        <Stat
          label="说生成了卡却没调工具"
          value={String(chat.claimedCardWithoutTool)}
          hint={`生成确认卡 ${chat.createdPending} 次，步骤超限 ${chat.hitMaxRounds} 次`}
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>按配置版本</CardTitle>
          <CardDescription>同一时间段里各配置版本的对话表现，用来看一次发布前后的变化。</CardDescription>
        </CardHeader>
        <CardContent>
          {data.byConfigVersion.length === 0 ? (
            <Empty />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>配置版本</TableHead>
                  <TableHead className="text-right">轮数</TableHead>
                  <TableHead className="text-right">失败率</TableHead>
                  <TableHead className="text-right">P50 / P95</TableHead>
                  <TableHead className="text-right">平均 token（入 / 出）</TableHead>
                  <TableHead className="text-right">没调工具却说有卡</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.byConfigVersion.map((row: ChatSummary & { configVersion: string }) => (
                  <TableRow key={row.configVersion}>
                    <TableCell className="font-mono">{row.configVersion}</TableCell>
                    <TableCell className="text-right">{row.count}</TableCell>
                    <TableCell className="text-right">{rate(row.errors, row.count)}</TableCell>
                    <TableCell className="text-right">
                      {seconds(row.p50)} / {seconds(row.p95)}
                    </TableCell>
                    <TableCell className="text-right">
                      {row.avgTokensIn ?? '—'} / {row.avgTokensOut ?? '—'}
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
            <CardTitle>错误码</CardTitle>
          </CardHeader>
          <CardContent>
            {data.errorCodes.length === 0 ? (
              <Empty text="这段时间没有错误。" />
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
                    <Badge variant="outline">{TYPES[row.type] ?? row.type}</Badge>
                    <span className="ml-auto tabular-nums">{row.count}</span>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>配置拉取</CardTitle>
          </CardHeader>
          <CardContent className="flex gap-6 text-sm">
            <span>更新 {data.configFetch.updated}</span>
            <span>没变 {data.configFetch.unchanged}</span>
            <span className={data.configFetch.failed ? 'text-destructive' : ''}>失败 {data.configFetch.failed}</span>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>工具</CardTitle>
          <CardDescription>手机上执行工具的结果码与耗时。失败多半是模型给的参数不对。</CardDescription>
        </CardHeader>
        <CardContent>
          {data.tools.length === 0 ? (
            <Empty />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>工具</TableHead>
                  <TableHead className="text-right">次数</TableHead>
                  <TableHead className="text-right">失败率</TableHead>
                  <TableHead className="text-right">P95</TableHead>
                  <TableHead>结果码</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.tools.map((row) => (
                  <TableRow key={row.tool}>
                    <TableCell className="font-mono">{row.tool}</TableCell>
                    <TableCell className="text-right">{row.count}</TableCell>
                    <TableCell className="text-right">{rate(row.failures, row.count)}</TableCell>
                    <TableCell className="text-right">{row.p95 === null ? '—' : `${row.p95} ms`}</TableCell>
                    <TableCell className="font-mono text-xs">
                      {Object.entries(row.codes)
                        .map(([code, n]) => `${code} ×${n}`)
                        .join('，')}
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
          <CardTitle>最近的事件</CardTitle>
          <CardDescription>最多 100 条。请求 ID 可以在 Conduit 的使用日志里对上同一次模型调用。</CardDescription>
        </CardHeader>
        <CardContent>
          {events.length === 0 ? (
            <Empty />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>时间</TableHead>
                  <TableHead>类型</TableHead>
                  <TableHead>结果</TableHead>
                  <TableHead className="text-right">耗时</TableHead>
                  <TableHead>配置</TableHead>
                  <TableHead>请求</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.map((event) => {
                  const result =
                    event.event_type === 'tool_call'
                      ? `${event.tool} → ${event.result_code}`
                      : [event.outcome, event.error_code].filter(Boolean).join(' · ')
                  const failed = event.outcome === 'error' || event.outcome === 'failed' || (event.result_code && event.result_code !== 'ok')
                  return (
                    <TableRow key={event.id}>
                      <TableCell className="whitespace-nowrap">{formatTime(event.occurred_at)}</TableCell>
                      <TableCell>{TYPES[event.event_type] ?? event.event_type}</TableCell>
                      <TableCell className={failed ? 'font-mono text-xs text-destructive' : 'font-mono text-xs'}>
                        {result}
                        {event.claimed_card_without_tool === 1 && <Badge className="ml-2" variant="destructive">没调工具却说有卡</Badge>}
                      </TableCell>
                      <TableCell className="text-right whitespace-nowrap">{event.latency_ms} ms</TableCell>
                      <TableCell className="font-mono text-xs">{event.config_version ?? '内置'}</TableCell>
                      <TableCell className="font-mono text-xs text-muted-foreground">
                        {event.request_id?.slice(0, 8) ?? '—'}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>安装</CardTitle>
          <CardDescription>
            匿名安装 ID，App 每 {RETENTION_DAYS} 天换一个，不含设备或用户信息。可以删除某个安装的全部诊断数据，或封禁它以拒收之后的上报。
          </CardDescription>
        </CardHeader>
        <CardContent>
          <InstallList />
        </CardContent>
      </Card>
    </div>
  )
}

function InstallList() {
  const installs = listInstalls()
  if (installs.length === 0) return <Empty />
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>安装 ID</TableHead>
          <TableHead>App / 系统</TableHead>
          <TableHead>首次 / 最近</TableHead>
          <TableHead className="text-right">事件</TableHead>
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
                  已封禁
                </Badge>
              )}
            </TableCell>
            <TableCell className="text-xs">
              {install.app_version} / iOS {install.os_version ?? '—'}
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

function Empty({ text = '这段时间没有数据。' }: { text?: string }) {
  return <p className="text-sm text-muted-foreground">{text}</p>
}
