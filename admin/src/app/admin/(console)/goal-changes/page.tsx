import type { GoalChangesResponse } from '@vita/contract'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import type { Messages } from '@/i18n/messages'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { goalChanges, vitaApiConfigured } from '@/server/vita-api'

export const generateMetadata = titled('goalChanges')

const seconds = (iso: string) => Math.floor(Date.parse(iso) / 1000)
const kcal = (value: number) => Math.round(value)

type GoalEntry = GoalChangesResponse['goals'][number]

function energyText(t: Messages, goal: GoalEntry['goal']): string {
  const plan = goal.energyPlan
  if (!plan) return goal.targets.energyKcal === null ? t.common.none : t.goalChanges.fixed(kcal(goal.targets.energyKcal))
  const adjustment =
    plan.adjustment.type === 'fraction' ? t.goalChanges.fraction(Math.round(plan.adjustment.value * 100)) : t.goalChanges.kcalAdjust(kcal(plan.adjustment.value))
  return `${t.goalChanges.auto(t.goalChanges.kinds[plan.kind] ?? plan.kind, adjustment)} · ${t.goalChanges.storedBmr(kcal(plan.bmrKcal))}`
}

/** 目标变更：基础代谢的变化与目标设置的历史，只读。 */
export default async function GoalChangesPage() {
  const t = await getT()
  if (!vitaApiConfigured()) {
    return (
      <div className="flex flex-col gap-6">
        <h1 className="text-xl font-semibold">{t.goalChanges.title}</h1>
        <Alert>
          <AlertTitle>{t.devices.notConfiguredTitle}</AlertTitle>
          <AlertDescription>{t.devices.notConfiguredBody}</AlertDescription>
        </Alert>
      </div>
    )
  }

  let data: GoalChangesResponse | null = null
  let loadError: string | null = null
  try {
    data = await goalChanges()
  } catch (error) {
    loadError = (error as Error).message
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">{t.goalChanges.title}</h1>
        <p className="text-sm text-muted-foreground">{t.goalChanges.description}</p>
      </div>
      {loadError && <p className="text-sm text-destructive">{t.goalChanges.loadFailed(loadError)}</p>}
      {data && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>{t.goalChanges.bmrTitle}</CardTitle>
            </CardHeader>
            <CardContent>
              {data.bmrChanges.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t.goalChanges.bmrEmpty}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t.goalChanges.time}</TableHead>
                      <TableHead>{t.goalChanges.reason}</TableHead>
                      <TableHead>{t.goalChanges.body}</TableHead>
                      <TableHead className="text-right">{t.goalChanges.bmr}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.bmrChanges.map((change) => {
                      const delta = kcal(change.bmrKcal - change.previousBmrKcal)
                      return (
                        <TableRow key={change.changedAt + change.bmrKcal}>
                          <TableCell className="whitespace-nowrap">{formatTime(seconds(change.changedAt))}</TableCell>
                          <TableCell>{t.goalChanges.reasons[change.reason] ?? change.reason}</TableCell>
                          <TableCell className="whitespace-nowrap">
                            {t.goalChanges.bodyText(change.weightKg, change.heightCm, change.ageYears, t.goalChanges.sex[change.sex] ?? change.sex)}
                          </TableCell>
                          <TableCell className="text-right whitespace-nowrap tabular-nums">
                            {kcal(change.previousBmrKcal)} → {kcal(change.bmrKcal)}
                            <span className="ml-2 text-xs text-muted-foreground">
                              {delta > 0 ? '+' : ''}
                              {delta}
                            </span>
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
              <CardTitle>{t.goalChanges.goalsTitle}</CardTitle>
            </CardHeader>
            <CardContent>
              {data.goals.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t.goalChanges.goalsEmpty}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t.goalChanges.time}</TableHead>
                      <TableHead>{t.goalChanges.effectiveFrom}</TableHead>
                      <TableHead>{t.goalChanges.origin}</TableHead>
                      <TableHead>{t.goalChanges.actor}</TableHead>
                      <TableHead>{t.goalChanges.energy}</TableHead>
                      <TableHead className="text-right">{t.goalChanges.protein}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.goals.map(({ goal, createdAt, actor }) => (
                      <TableRow key={goal.id}>
                        <TableCell className="whitespace-nowrap">{formatTime(seconds(createdAt))}</TableCell>
                        <TableCell className="whitespace-nowrap">{goal.effectiveFrom}</TableCell>
                        <TableCell>{t.goalChanges.origins[goal.origin] ?? goal.origin}</TableCell>
                        <TableCell className="font-mono text-xs">{actor ?? t.common.none}</TableCell>
                        <TableCell>{energyText(t, goal)}</TableCell>
                        <TableCell className="text-right tabular-nums">{goal.targets.proteinG === null ? t.common.none : `${kcal(goal.targets.proteinG)} g`}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  )
}
