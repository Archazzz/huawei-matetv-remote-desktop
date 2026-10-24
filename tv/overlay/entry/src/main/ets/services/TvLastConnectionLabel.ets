/** Historical connection evidence, never an assertion that a computer is online. */
export function tvLastConnectionLabel(timestamp: number, now: number = Date.now()): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > now) { return '尚未连接'; }
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) { return '尚未连接'; }
  const today: Date = new Date(now);
  const time: string = `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
  if (date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() &&
      date.getDate() === today.getDate()) {
    return `上次连接 今天 ${time}`;
  }
  const year: string = date.getFullYear() === today.getFullYear() ? '' : `${date.getFullYear()}/`;
  return `上次连接 ${year}${date.getMonth() + 1}/${date.getDate()} ${time}`;
}
