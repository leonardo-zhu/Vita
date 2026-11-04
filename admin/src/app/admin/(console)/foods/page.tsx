import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { foods, vitaApiConfigured } from '@/server/vita-api'

import { FoodList } from './food-list'

export const generateMetadata = titled('foods')

export default async function FoodsPage() {
  const t = await getT()
  if (!vitaApiConfigured()) {
    return (
      <Alert>
        <AlertTitle>{t.devices.notConfiguredTitle}</AlertTitle>
        <AlertDescription>{t.devices.notConfiguredBody}</AlertDescription>
      </Alert>
    )
  }
  let products: Awaited<ReturnType<typeof foods>>
  try {
    products = await foods()
  } catch (error) {
    return <p className="text-sm text-destructive">{t.data.loadFailed((error as Error).message)}</p>
  }
  const sorted = [...products].sort((a, b) => (b.activeVersion?.createdAt ?? '').localeCompare(a.activeVersion?.createdAt ?? ''))

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold">{t.data.foodsTitle}</h1>
      <p className="text-sm text-muted-foreground">{t.data.foodsDescription}</p>
      {sorted.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t.data.noFoods}</p>
      ) : (
        <FoodList
          products={sorted.map((product) => ({
            id: product.id,
            name: product.name,
            brand: product.brandOrSupplier,
            aliases: product.aliases,
            note: product.note,
            package: product.package,
            activeVersionId: product.activeVersion?.id ?? null,
            labelScanId: product.activeVersion?.labelScanId ?? null,
            versions: product.versions.map((version) => ({
              id: version.id,
              active: version.id === product.activeVersion?.id,
              basis: version.basis,
              source: version.sourceKind,
              sourceNote: version.sourceNote,
              createdAt: formatTime(Math.floor(Date.parse(version.createdAt) / 1000)),
            })),
          }))}
        />
      )}
    </div>
  )
}
