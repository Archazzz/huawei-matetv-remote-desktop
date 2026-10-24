import { common, Want, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { notificationManager } from '@kit.NotificationKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { HostSyncService } from '../HostSyncService';
import { TV_COMPUTER_PRESETS } from '../TvProvisionedComputers';
import { TvNotificationEvent, TvNotificationBatch, TvNotificationRoute, notificationKey,
  validNotificationEvent, validNotificationBatch, resolveNotificationHost } from './TvNotificationPolicy';

interface TvNotificationConfig {
  version: number; endpoint: string; token: string; caResource: string; publicKeyHash: string;
}
interface SeenNotification { key: string; expiresAt: number; }
interface NotificationClick { token: string; key: string; expiresAt: number; }
interface SavedNotifications {
  streamId: string; cursor: number; events: TvNotificationEvent[]; seen: SeenNotification[]; clicks: NotificationClick[];
}
export const TV_NOTIFICATION_CLICK: string = 'screenLinkNotificationClick';
export class TvNotificationService {
  private static instance: TvNotificationService = new TvNotificationService();
  static getInstance(): TvNotificationService { return TvNotificationService.instance; }
  private context: common.UIAbilityContext | null = null;
  private config: TvNotificationConfig | null = null;
  private caPath: string = '';
  private store: preferences.Preferences | null = null;
  private scope: string = '';
  private foreground: boolean = false;
  private enabled: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private request: http.HttpRequest | null = null;
  private busy: boolean = false;
  private streamId: string = '';
  private cursor: number = 0;
  private events: TvNotificationEvent[] = [];
  private seen: SeenNotification[] = [];
  private clicks: NotificationClick[] = [];
  private pendingWantToken: string = '';
  private route: TvNotificationRoute = new TvNotificationRoute();
  private statusText: string = '通知同步尚未配置';
  private notificationId: number = 810000;

  attach(context: common.UIAbilityContext): void { this.context = context; }
  receiveWant(want: Want): void {
    const token: Object | undefined = want.parameters?.[TV_NOTIFICATION_CLICK];
    if (typeof token !== 'string' || !/^[a-f0-9-]{36}$/.test(token)) { return; }
    // Exported abilities can receive forged Wants. Only a nonce created by this
    // installation for a published notification can identify a pending click.
    this.pendingWantToken = token;
    if (this.store !== null) { this.consumeWantToken(); }
    this.changed();
  }
  private consumeWantToken(): void {
    const token: string = this.pendingWantToken;
    if (token.length === 0) { return; }
    this.pendingWantToken = '';
    const click: NotificationClick | undefined = this.clicks.find((item: NotificationClick): boolean =>
      item.token === token && item.expiresAt > Date.now());
    if (click !== undefined) { this.route.request(click.key); }
  }
  setForeground(value: boolean): void {
    this.foreground = value;
    this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    this.request?.destroy(); this.request = null;
    if (value) { this.schedule(100); }
    this.changed();
  }
  initialize(context: common.UIAbilityContext): void {
    this.attach(context);
    const scope: string = AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
    if (scope === this.scope && this.store !== null) { return; }
    this.generation++;
    if (this.scope.length > 0) { this.route.clear(); }
    this.scope = scope;
    this.events = []; this.seen = []; this.clicks = []; this.cursor = 0; this.streamId = '';
    this.store = preferences.getPreferencesSync(context, { name: 'ScreenLinkNotifications' });
    this.enabled = this.store.getSync(scope + ':enabled', false) === true;
    this.notificationId = this.store.getSync('notificationId', 810000) as number;
    try {
      const saved: SavedNotifications = JSON.parse(this.store.getSync(scope + ':inbox', '{}') as string) as SavedNotifications;
      const now: number = Date.now();
      if (Array.isArray(saved.events)) { this.events = saved.events.filter((e: TvNotificationEvent): boolean => validNotificationEvent(e, now)).slice(-100); }
      if (Array.isArray(saved.seen)) { this.seen = saved.seen.filter((e: SeenNotification): boolean =>
        typeof e.key === 'string' && e.key.length <= 257 && Number.isSafeInteger(e.expiresAt) && e.expiresAt > now).slice(-10000); }
      if (Array.isArray(saved.clicks)) { this.clicks = saved.clicks.filter((item: NotificationClick): boolean =>
        typeof item.token === 'string' && /^[a-f0-9-]{36}$/.test(item.token) &&
        typeof item.key === 'string' && item.key.length <= 257 && Number.isSafeInteger(item.expiresAt) && item.expiresAt > now).slice(-100); }
      if (typeof saved.streamId === 'string') { this.streamId = saved.streamId; }
      if (Number.isSafeInteger(saved.cursor) && saved.cursor >= 0) { this.cursor = saved.cursor; }
    } catch (_error) { /* Malformed local state is discarded. */ }
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
      const raw: Uint8Array = context.resourceManager.getRawFileContentSync('screenlink-notifications.json');
      const cfg: TvNotificationConfig = JSON.parse(decoder.decodeToString(raw)) as TvNotificationConfig;
      if (cfg.version !== 1 || !/^https:\/\/[A-Za-z0-9.-]+:[0-9]{1,5}$/.test(cfg.endpoint) ||
          !/^[A-Za-z0-9_-]{32,256}$/.test(cfg.token) || cfg.caResource !== 'screenlink-notifications-ca.pem' ||
          !/^[A-Za-z0-9+/]{43}=$/.test(cfg.publicKeyHash)) { throw new Error('invalid config'); }
      const ca: Uint8Array = context.resourceManager.getRawFileContentSync(cfg.caResource);
      this.caPath = context.filesDir + '/screenlink-notifications-ca.pem';
      const file: fileIo.File = fileIo.openSync(this.caPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, ca.buffer); } finally { fileIo.closeSync(file); }
      this.config = cfg;
      this.statusText = this.enabled ? '前台接收已开启' : '前台接收已关闭';
    } catch (_error) { this.config = null; this.statusText = '通知同步尚未配置'; }
    this.consumeWantToken();
    this.schedule(100);
    this.changed();
  }
  configured(): boolean { return this.config !== null; }
  isEnabled(): boolean { return this.enabled; }
  status(): string { return this.statusText; }
  inbox(): TvNotificationEvent[] { return this.events.filter((e: TvNotificationEvent): boolean => validNotificationEvent(e, Date.now())).slice().reverse(); }
  setEnabled(value: boolean): void {
    if (this.config === null || this.store === null) { return; }
    this.enabled = value; this.generation++;
    this.store.putSync(this.scope + ':enabled', value); this.store.flushSync();
    this.request?.destroy(); this.request = null;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    this.statusText = value ? '前台接收已开启' : '前台接收已关闭';
    this.schedule(100); this.changed();
  }
  clearHistory(): void { this.events = []; this.clicks = []; this.route.clear(); this.save(); this.changed(); }
  async enableSystemNotifications(): Promise<boolean> {
    if (this.context === null) { return false; }
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        await notificationManager.requestEnableNotification(this.context);
      }
      return await notificationManager.isNotificationEnabled();
    } catch (_error) { return false; }
  }
  click(key: string): void { this.route.request(key); this.changed(); }
  pendingHost(): string {
    if (this.route.pendingKey.length === 0 || this.scope.length === 0) { return ''; }
    if (AccountSessionCoordinator.getInstance().currentScope().ownerScopeId !== this.scope) { return ''; }
    const event: TvNotificationEvent | undefined = this.events.find((e: TvNotificationEvent): boolean =>
      notificationKey(e) === this.route.pendingKey && validNotificationEvent(e, Date.now()));
    const target: string = event === undefined ? '' : resolveNotificationHost(event.hostId, this.scope,
      HostSyncService.getInstance().getAllHosts(), TV_COMPUTER_PRESETS);
    if (target.length === 0) { this.route.clear(); this.statusText = '通知已过期或对应电脑不可用'; this.changed(); }
    return target;
  }
  routeAction(activeHost: string, remoteMounted: boolean, leaving: boolean): string {
    if (!this.foreground) { return 'none'; }
    return this.route.decide(this.pendingHost(), activeHost, remoteMounted, leaving);
  }
  consume(): void { this.route.clear(); this.changed(); }
  private changed(): void {
    AppStorage.setOrCreate('screenLinkNotificationsRevision', (AppStorage.get<number>('screenLinkNotificationsRevision') ?? 0) + 1);
  }
  private save(): void {
    const snapshot: SavedNotifications = { streamId: this.streamId, cursor: this.cursor, events: this.events, seen: this.seen, clicks: this.clicks };
    this.store?.putSync(this.scope + ':inbox', JSON.stringify(snapshot));
    this.store?.flushSync();
  }
  private schedule(delay: number): void {
    if (!this.foreground || !this.enabled || this.config === null || this.timer >= 0) { return; }
    this.timer = setTimeout((): void => { this.timer = -1; void this.poll(); }, delay);
  }
  private async poll(): Promise<void> {
    if (this.busy) { this.schedule(1000); return; }
    const cfg: TvNotificationConfig | null = this.config;
    if (!this.foreground || !this.enabled || cfg === null || this.store === null ||
        AccountSessionCoordinator.getInstance().currentScope().ownerScopeId !== this.scope) { return; }
    const generation: number = this.generation;
    this.busy = true;
    const request: http.HttpRequest = http.createHttp(); this.request = request;
    try {
      const response: http.HttpResponse = await request.request(cfg.endpoint + '/v1/events?after=' + this.cursor.toString(), {
        method: http.RequestMethod.GET, header: { Authorization: 'Bearer ' + cfg.token },
        expectDataType: http.HttpDataType.STRING, usingCache: false, usingProxy: false,
        caPath: this.caPath, certificatePinning: { publicKeyHash: cfg.publicKeyHash, hashAlgorithm: 'SHA-256' },
        maxRedirects: 0, connectTimeout: 5000, readTimeout: 8000, maxLimit: 4 * 1024 * 1024
      });
      if (generation !== this.generation || !this.foreground || !this.enabled) { return; }
      if (response.responseCode !== 200 || typeof response.result !== 'string') { throw new Error('response rejected'); }
      const batch: TvNotificationBatch = JSON.parse(response.result) as TvNotificationBatch;
      if (!validNotificationBatch(batch)) { throw new Error('invalid events'); }
      if ((this.streamId.length > 0 && batch.streamId !== this.streamId) || batch.resetRequired) {
        this.streamId = batch.streamId; this.cursor = 0; this.save(); return;
      }
      if (batch.nextCursor < this.cursor) { throw new Error('cursor rollback'); }
      const now: number = Date.now();
      this.seen = this.seen.filter((e: SeenNotification): boolean => e.expiresAt > now);
      this.events = this.events.filter((e: TvNotificationEvent): boolean => validNotificationEvent(e, now));
      for (const event of batch.events) {
        if (generation !== this.generation || !this.foreground || !this.enabled) { return; }
        if (!validNotificationEvent(event, now) || this.seen.some((e: SeenNotification): boolean => e.key === notificationKey(event))) { continue; }
        this.seen.push({ key: notificationKey(event), expiresAt: event.expiresAt });
        this.events.push(event);
        // Persist deduplication before publishing; a process restart must not replay alerts.
        this.events = this.events.slice(-100); this.seen = this.seen.slice(-10000); this.save();
        await this.publish(event, generation);
      }
      if (generation !== this.generation || !this.foreground || !this.enabled) { return; }
      this.streamId = batch.streamId; this.cursor = batch.nextCursor; this.save();
      this.statusText = '前台接收已开启'; this.changed();
    } catch (error) {
      const code: number = (error as BusinessError).code;
      hilog.warn(0x0016, 'TvNotifications', 'poll failed code=%{public}d', Number.isFinite(code) ? code : -1);
      if (generation === this.generation) { this.statusText = '暂时无法接收通知，正在重试'; this.changed(); }
    } finally {
      request.destroy(); if (this.request === request) { this.request = null; }
      this.busy = false; this.schedule(3000);
    }
  }
  private async publish(event: TvNotificationEvent, generation: number): Promise<void> {
    try {
      if (!await notificationManager.isNotificationEnabled() || this.context === null ||
          generation !== this.generation || !this.foreground || !this.enabled) { return; }
      const id: number = ++this.notificationId;
      this.store?.putSync('notificationId', id); this.store?.flushSync();
      const token: string = util.generateRandomUUID(false);
      this.clicks = this.clicks.filter((item: NotificationClick): boolean => item.expiresAt > Date.now());
      this.clicks.push({ token, key: notificationKey(event), expiresAt: event.expiresAt });
      this.clicks = this.clicks.slice(-100); this.save();
      const parameters: Record<string, Object> = {}; parameters[TV_NOTIFICATION_CLICK] = token;
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: 'EntryAbility', parameters }],
        actionType: wantAgent.OperationType.START_ABILITY, requestCode: id,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      });
      if (generation !== this.generation || !this.foreground || !this.enabled) { return; }
      await notificationManager.publish({ id, label: notificationKey(event), wantAgent: agent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        tapDismissed: true, isAlertOnce: true, autoDeletedTime: event.expiresAt,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: event.title || event.appName, text: event.body,
            additionalText: event.deviceName + ' · ' + event.appName } }
      });
    } catch (_error) { /* Inbox remains usable when the OS rejects a banner. */ }
  }
}
