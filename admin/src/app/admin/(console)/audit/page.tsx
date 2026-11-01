import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatTime } from '@/lib/format'
import { listAudit, type AuditAction } from '@/server/audit'

export const metadata = { title: '审计 · Vita Admin' }

const ACTIONS: Record<AuditAction, string> = {
  login: '登录',
  login_failed: '登录失败',
  logout: '退出',
  passkey_add: '添加 Passkey',
  passkey_remove: '删除 Passkey',
  draft_save: '保存草稿',
  draft_reset: '放弃草稿',
  publish: '发布',
  rollback: '回滚',
}

export default async function AuditPage() {
  const rows = listAudit()
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">审计</h1>
        <p className="text-sm text-muted-foreground">最近 200 条操作。记录只追加，不能修改或删除。</p>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>时间</TableHead>
            <TableHead>操作</TableHead>
            <TableHead>对象</TableHead>
            <TableHead>操作者</TableHead>
            <TableHead>IP</TableHead>
            <TableHead>详情</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id}>
              <TableCell className="whitespace-nowrap">{formatTime(row.at)}</TableCell>
              <TableCell>{ACTIONS[row.action] ?? row.action}</TableCell>
              <TableCell className="font-mono text-xs">{row.target_id || '—'}</TableCell>
              <TableCell>{row.actor}</TableCell>
              <TableCell className="font-mono text-xs">{row.ip || '—'}</TableCell>
              <TableCell className="max-w-sm">
                {row.diff && row.diff !== 'null' ? (
                  <details>
                    <summary className="cursor-pointer text-xs text-muted-foreground">展开</summary>
                    <pre className="mt-1 overflow-auto rounded bg-muted p-2 text-xs whitespace-pre-wrap">
                      {JSON.stringify(JSON.parse(row.diff), null, 2)}
                    </pre>
                  </details>
                ) : (
                  '—'
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
