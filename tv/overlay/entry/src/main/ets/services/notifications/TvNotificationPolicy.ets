export interface TvNotificationEvent {
  cursor: number;
  eventId: string;
  deviceId: string;
  deviceName: string;
  hostId: string;
  appId: string;
  appName: string;
  title: string;
  body: string;
  createdAt: number;
  expiresAt: number;
  contentState: string;
}
export interface TvNotificationBatch {
  streamId: string;
  events: TvNotificationEvent[];
  nextCursor: number;
  resetRequired: boolean;
}
export interface TvNotificationHost {
  id: string;
  userId: string;
  protocol: string;
  rustdeskDirectEnabled: boolean;
  rustdeskDirectHost: string;
  rustdeskDirectPort: number;
}
export interface TvNotificationPreset { id: string; address: string; port: number; }
export function notificationKey(event: TvNotificationEvent): string {
  return event.deviceId + '/' + event.eventId;
}
function boundedText(value: string, limit: number): boolean {
  return typeof value === 'string' && value.length <= limit && !/[\u0000\u0001-\u0008\u000B\u000C\u000E-\u001F]/.test(value);
}
export function validNotificationEvent(event: TvNotificationEvent, now: number): boolean {
  return event !== null && typeof event === 'object' &&
    Number.isSafeInteger(event.cursor) && event.cursor > 0 &&
    typeof event.eventId === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(event.eventId) &&
    typeof event.deviceId === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(event.deviceId) &&
    boundedText(event.deviceName, 128) && event.deviceName.length > 0 &&
    boundedText(event.hostId, 160) && event.hostId.length > 0 &&
    (event.appId === 'codex' || event.appId === 'wechat') &&
    boundedText(event.appName, 128) && event.appName.length > 0 &&
    boundedText(event.title, 512) && boundedText(event.body, 8192) &&
    (event.title.length > 0 || event.body.length > 0) &&
    Number.isSafeInteger(event.createdAt) && Number.isSafeInteger(event.expiresAt) &&
    event.createdAt >= 0 && event.createdAt <= now + 60000 && event.expiresAt - event.createdAt <= 86400000 && event.expiresAt > event.createdAt && event.expiresAt > now &&
    ['complete', 'truncated', 'hidden', 'unknown'].includes(event.contentState);
}
export function validNotificationBatch(batch: TvNotificationBatch): boolean {
  if (batch === null || typeof batch !== 'object' || typeof batch.streamId !== 'string' ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(batch.streamId) || !Array.isArray(batch.events) ||
      batch.events.length > 100 || !Number.isSafeInteger(batch.nextCursor) || batch.nextCursor < 0 ||
      typeof batch.resetRequired !== 'boolean') { return false; }
  let previous: number = 0;
  for (const event of batch.events) {
    if (event === null || typeof event !== 'object' || !Number.isSafeInteger(event.cursor) ||
        event.cursor <= previous || event.cursor > batch.nextCursor) { return false; }
    previous = event.cursor;
  }
  return true;
}
export function resolveNotificationHost(target: string, scope: string,
  hosts: TvNotificationHost[], presets: TvNotificationPreset[]): string {
  if (scope.length === 0) { return ''; }
  let candidates: TvNotificationHost[];
  if (target.startsWith('preset:')) {
    const matches: TvNotificationPreset[] = presets.filter((preset: TvNotificationPreset): boolean =>
      'preset:' + preset.id === target);
    if (matches.length !== 1) { return ''; }
    const preset: TvNotificationPreset = matches[0];
    candidates = hosts.filter((host: TvNotificationHost): boolean => host.userId === scope &&
      host.protocol === 'rustdesk' && host.rustdeskDirectEnabled &&
      host.rustdeskDirectHost === preset.address && host.rustdeskDirectPort === preset.port);
  } else {
    candidates = hosts.filter((host: TvNotificationHost): boolean =>
      host.userId === scope && host.protocol === 'rustdesk' && host.id === target);
  }
  return candidates.length === 1 ? candidates[0].id : '';
}
// Arrival never requests routing. Only a validated user click sets pendingKey.
export class TvNotificationRoute {
  pendingKey: string = '';
  request(key: string): void { this.pendingKey = key; }
  clear(): void { this.pendingKey = ''; }
  decide(targetHost: string, activeHost: string, remoteMounted: boolean, leaving: boolean): string {
    if (this.pendingKey.length === 0 || targetHost.length === 0) { return 'none'; }
    if (leaving) { return 'wait'; }
    if (remoteMounted) { return targetHost === activeHost ? 'same' : 'leave'; }
    return 'open';
  }
}
