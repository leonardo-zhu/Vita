import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
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
          products={sorted.map((product) => {
            const basis = product.activeVersion?.basis
            return {
              id: product.id,
              name: product.name,
              brand: product.brandOrSupplier,
              packageText: product.package ? `${product.package.amount} ${product.package.unit}` : null,
              basisText: basis ? `${basis.quantity.amount} ${basis.quantity.unit}` : null,
              nutrients: basis
                ? `${Math.round(basis.nutrients.energyKcal)} kcal · P ${basis.nutrients.proteinG} g · F ${basis.nutrients.fatG} g · C ${basis.nutrients.carbohydrateG} g`
                : null,
              versions: product.versions.length,
              labelScanId: product.activeVersion?.labelScanId ?? null,
            }
          })}
        />
      )}
    </div>
  )
}
