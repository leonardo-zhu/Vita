import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { listAudit } from '@/server/audit'

export const generateMetadata = titled('audit')

export default async function AuditPage() {
  const t = await getT()
  const rows = listAudit()
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">{t.audit.title}</h1>
        <p className="text-sm text-muted-foreground">{t.audit.description}</p>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t.audit.time}</TableHead>
            <TableHead>{t.audit.action}</TableHead>
            <TableHead>{t.audit.target}</TableHead>
            <TableHead>{t.audit.actor}</TableHead>
            <TableHead>{t.audit.ip}</TableHead>
            <TableHead>{t.audit.detail}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id}>
              <TableCell className="whitespace-nowrap">{formatTime(row.at)}</TableCell>
              <TableCell>{t.audit.actions[row.action] ?? row.action}</TableCell>
              <TableCell className="font-mono text-xs">{row.target_id || t.common.none}</TableCell>
              <TableCell>{row.actor}</TableCell>
              <TableCell className="font-mono text-xs">{row.ip || t.common.none}</TableCell>
              <TableCell className="max-w-sm">
                {row.diff && row.diff !== 'null' ? (
                  <details>
                    <summary className="cursor-pointer text-xs text-muted-foreground">{t.common.expand}</summary>
                    <pre className="mt-1 overflow-auto rounded bg-muted p-2 text-xs whitespace-pre-wrap">
                      {JSON.stringify(JSON.parse(row.diff), null, 2)}
                    </pre>
                  </details>
                ) : (
                  t.common.none
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
