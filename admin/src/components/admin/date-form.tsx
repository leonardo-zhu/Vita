import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

/** 按日期查看：普通的 GET 表单，日期写进地址栏，刷新和分享都保留。 */
export function DateForm({ date, label, submit }: { date: string; label: string; submit: string }) {
  return (
    <form className="flex items-center gap-2" method="get">
      <label className="text-sm text-muted-foreground" htmlFor="date">
        {label}
      </label>
      <Input id="date" name="date" type="date" defaultValue={date} className="w-auto" />
      <Button type="submit" variant="outline" size="sm">
        {submit}
      </Button>
    </form>
  )
}
