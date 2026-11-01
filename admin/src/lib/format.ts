/** unix 秒 → 北京时间的 `YYYY-MM-DD HH:mm` */
export function formatTime(seconds: number | null | undefined): string {
  if (!seconds) return '—'
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  })
    .format(new Date(seconds * 1000))
    .replaceAll('/', '-')
}
