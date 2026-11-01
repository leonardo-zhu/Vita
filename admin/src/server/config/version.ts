/**
 * configVersion：`YYYY-MM-DD.n`，单调递增（vita-admin.md §4）。
 * 不能按字符串比较（`.10` 会排在 `.9` 前面），先比日期再按数字比序号。iOS 端的比较规则与此相同。
 */
const PATTERN = /^(\d{4}-\d{2}-\d{2})\.(\d+)$/

export function parseConfigVersion(value: string): { date: string; n: number } | null {
  const m = PATTERN.exec(value)
  return m ? { date: m[1], n: Number(m[2]) } : null
}

/** a < b 为负，相等为 0，a > b 为正；格式不对的排在最前 */
export function compareConfigVersion(a: string, b: string): number {
  const pa = parseConfigVersion(a)
  const pb = parseConfigVersion(b)
  if (!pa || !pb) return (pa ? 1 : 0) - (pb ? 1 : 0)
  if (pa.date !== pb.date) return pa.date < pb.date ? -1 : 1
  return pa.n - pb.n
}

/** 发布用的日期按北京时间算，和 R4S 容器的 TZ 一致 */
export function todayInShanghai(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now)
}

/**
 * 下一个版本号：比 floor（已发布的最新版本、内置默认值的版本里较大的）大。
 * 今天已发过就序号加一；服务器时钟比最新版本的日期还早时沿用那个日期，保证单调。
 */
export function nextConfigVersion(floor: string | null, today: string): string {
  const latest = floor ? parseConfigVersion(floor) : null
  if (!latest || latest.date < today) return `${today}.1`
  return `${latest.date}.${latest.n + 1}`
}
