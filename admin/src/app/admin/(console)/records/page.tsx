import { DateForm } from '@/components/admin/date-form'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { clock, isLocalDate, todayInShanghai } from '@/lib/dates'
import { day, vitaApiConfigured } from '@/server/vita-api'

import { RecordList } from './record-list'

export const generateMetadata = titled('records')

const MEAL: Record<string, string> = { breakfast: '早餐', lunch: '午餐', dinner: '晚餐', snack: '加餐', other: '其他' }

export default async function RecordsPage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
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
  const date = isLocalDate(requested) ? requested : todayInShanghai()
  let loaded: Awaited<ReturnType<typeof day>>
  try {
    loaded = await day(date)
  } catch (error) {
    return <p className="text-sm text-destructive">{t.data.loadFailed((error as Error).message)}</p>
  }
  const totals = loaded.summary.totals

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold">{t.data.recordsTitle}</h1>
        <DateForm date={date} label={t.data.pickDate} submit={t.data.go} />
      </div>
      <p className="text-sm text-muted-foreground">{t.data.recordsDescription}</p>
      <p className="text-sm">
        {t.data.totals}：{Math.round(totals.energyKcal)} kcal · P {totals.proteinG.toFixed(1)} g · F {totals.fatG.toFixed(1)} g · C {totals.carbohydrateG.toFixed(1)} g
        {totals.sodiumMg !== undefined && ` · Na ${Math.round(totals.sodiumMg)} mg`}
        {totals.sugarG !== undefined && ` · ${t.data.sugar} ${totals.sugarG.toFixed(1)} g`}
        {loaded.summary.missingExtras.sodiumMg > 0 && totals.sodiumMg !== undefined && (
          <span className="ml-2 text-xs text-muted-foreground">{t.data.missingExtras(loaded.summary.missingExtras.sodiumMg)}</span>
        )}
        <span className="ml-2 text-xs text-muted-foreground">{t.data.revision(loaded.revision)}</span>
      </p>
      {loaded.records.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t.data.noRecords}</p>
      ) : (
        <RecordList
          date={date}
          revision={loaded.revision}
          records={loaded.records.map((record) => ({
            id: record.id,
            title: [record.mealLabel ?? (record.eventTime.mealPeriod ? MEAL[record.eventTime.mealPeriod] : null), record.eventTime.timestamp ? clock(record.eventTime.timestamp) : null]
              .filter(Boolean)
              .join(' · '),
            energy: Math.round(record.totals.energyKcal),
            items: record.items.map((item) => ({
              id: item.id,
              name: item.groupName ? `${item.groupName} / ${item.displayName}` : item.displayName,
              amount: item.originalAmountText,
              unit: item.quantity?.unit ?? null,
              quantity: item.quantity?.amount ?? null,
              source: item.sourceLabel ?? item.snapshot.nutritionSource,
              energy: Math.round(item.snapshot.values.energyKcal),
              protein: item.snapshot.values.proteinG.toFixed(1),
            })),
          }))}
        />
      )}
    </div>
  )
}
