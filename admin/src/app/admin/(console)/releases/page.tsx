import { titled } from '@/i18n/metadata'
import Link from 'next/link'

import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatTime } from '@/lib/format'
import { getT } from '@/i18n/server'
import { currentRelease, listReleases } from '@/server/config/service'

export const generateMetadata = titled('releases')

export default async function ReleasesPage() {
  const t = await getT()
  const releases = listReleases()
  const currentId = currentRelease()?.id
  const rollbackVersion = (id: number) => releases.find((release) => release.id === id)?.config_version ?? `#${id}`
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold">{t.releases.title}</h1>
        <Link href="/admin/releases/compare" className="text-sm underline-offset-4 hover:underline">
          {t.releases.compareLink}
        </Link>
      </div>
      {releases.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t.releases.empty}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t.releases.version}</TableHead>
              <TableHead>{t.releases.publishedAt}</TableHead>
              <TableHead>{t.releases.publishedBy}</TableHead>
              <TableHead>{t.releases.note}</TableHead>
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
                      {t.releases.live}
                    </Badge>
                  )}
                </TableCell>
                <TableCell>{formatTime(release.published_at)}</TableCell>
                <TableCell>{release.published_by}</TableCell>
                <TableCell className="max-w-xs truncate text-muted-foreground">{release.note || (release.rollback_of ? t.releases.rollbackOf(rollbackVersion(release.rollback_of)) : t.common.none)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
