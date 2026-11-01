import Link from 'next/link'

import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatTime } from '@/lib/format'
import { currentRelease, listReleases } from '@/server/config/service'

export const metadata = { title: '发布历史 · Vita Admin' }

export default async function ReleasesPage() {
  const releases = listReleases()
  const currentId = currentRelease()?.id
  return (
    <div className="flex flex-col gap-4">
      <h1 className="text-xl font-semibold">发布历史</h1>
      {releases.length === 0 ? (
        <p className="text-sm text-muted-foreground">还没有发布过。</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>版本</TableHead>
              <TableHead>发布时间</TableHead>
              <TableHead>发布人</TableHead>
              <TableHead>备注</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {releases.map((release) => (
              <TableRow key={release.id}>
                <TableCell>
                  <Link href={`/admin/releases/${release.id}`} className="font-mono underline-offset-4 hover:underline">
                    {release.config_version}
                  </Link>
                  {release.id === currentId && (
                    <Badge className="ml-2" variant="outline">
                      线上
                    </Badge>
                  )}
                </TableCell>
                <TableCell>{formatTime(release.published_at)}</TableCell>
                <TableCell>{release.published_by}</TableCell>
                <TableCell className="max-w-xs truncate text-muted-foreground">{release.note || '—'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
