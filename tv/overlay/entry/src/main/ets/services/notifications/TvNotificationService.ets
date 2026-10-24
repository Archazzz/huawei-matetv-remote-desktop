import { common, Want, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { HostSyncService } from '../HostSyncService';
import { TV_COMPUTER_PRESETS } from '../TvProvisionedComputers';
import { TvNotificationEvent, TvNotificationBatch, TvNotificationRoute, notificationKey,
  validNotificationEvent, validNotificationBatch, resolveNotificationHost } from './TvNotificationPolicy';
import { TV_PUSH_NONCE, TV_PUSH_INSTALLATION, validPushInstallation, validPushClick, pushErrorText } from './TvPushPolicy';

interface TvNotificationConfig {
  version: number; endpoint: string; token: string; caResource: string; publicKeyHash: string;
}
interface SeenNotification { key: string; expiresAt: number; }
interface NotificationClick { token: string; key: string; expiresAt: number; }
interface PushRegistration { registered: boolean; cloudConfigured: boolean; }
interface PushResolution { event: TvNotificationEvent; streamId: string; scope: string; }
interface PushRevocation { revoked: boolean; }
interface PushRegisterRequest { installationId: string; pushToken: string; previewMode: string; scope: string; }
interface PushRevokeRequest { installationId: string; }
interface PushResolveRequest { installationId: string; clickNonce: string; scope: string; }
class PushHttpError extends Error {
  code: number;
  constructor(code: number) { super('push response rejected'); this.code = code; }
}
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
  private installationId: string = '';
  private backgroundEnabled: boolean = false;
  private backgroundReady: boolean = false;
  private backgroundBusy: boolean = false;
  private backgroundStatus: string = '后台推送未开启';
  private pushGeneration: number = 0;
  private pushRevokePending: boolean = false;
  private pendingPushNonce: string = '';
  private pendingPushInstallation: string = '';
  private pushResolveBusy: boolean = false;
  private pushRefreshAttempted: boolean = false;

  attach(context: common.UIAbilityContext): void { this.context = context; }
  receiveWant(want: Want): void {
    const cloudNonce: Object | undefined = want.parameters?.[TV_PUSH_NONCE];
    const cloudInstallation: Object | undefined = want.parameters?.[TV_PUSH_INSTALLATION];
    if (typeof cloudNonce === 'string' && typeof cloudInstallation === 'string' &&
        /^[A-Za-z0-9_-]{43}$/.test(cloudNonce) && validPushInstallation(cloudInstallation)) {
      // Cloud clicks are untrusted until resolved over the paired TLS channel.
      this.pendingPushNonce = cloudNonce; this.pendingPushInstallation = cloudInstallation;
      void this.resolvePushClick();
      return;
    }
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
    if (value) { this.schedule(100); void this.resumePush(); }
    this.changed();
  }
  initialize(context: common.UIAbilityContext): void {
    this.attach(context);
    const scope: string = AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
    if (scope === this.scope && this.store !== null) { void this.resumePush(); return; }
    this.generation++;
    this.pushGeneration++;
    this.pushRefreshAttempted = false;
    if (this.scope.length > 0) {
      this.route.clear(); this.pendingPushNonce = ''; this.pendingPushInstallation = '';
      if (this.backgroundEnabled) { this.markPushRevocation(); }
    }
    this.scope = scope;
    this.events = []; this.seen = []; this.clicks = []; this.cursor = 0; this.streamId = '';
    this.store = preferences.getPreferencesSync(context, { name: 'ScreenLinkNotifications' });
    this.installationId = this.store.getSync('pushInstallationId', '') as string;
    if (!validPushInstallation(this.installationId)) {
      this.installationId = util.generateRandomUUID(false);
      this.store.putSync('pushInstallationId', this.installationId); this.store.flushSync();
    }
    const registeredScope: string = this.store.getSync('pushScope', '') as string;
    this.backgroundEnabled = this.store.getSync('pushEnabled', false) === true && registeredScope === scope;
    if (registeredScope.length > 0 && registeredScope !== scope && this.store.getSync('pushEnabled', false) === true) {
      this.markPushRevocation();
    }
    this.pushRevokePending = this.store.getSync('pushRevokePending', false) === true;
    this.backgroundReady = false;
    this.backgroundStatus = this.backgroundEnabled ? '后台登记待检查' : '后台推送未开启';
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
    void this.resumePush();
    this.schedule(100);
    this.changed();
  }
  configured(): boolean { return this.config !== null; }
  isEnabled(): boolean { return this.enabled; }
  status(): string { return this.statusText; }
  isBackgroundEnabled(): boolean { return this.backgroundEnabled; }
  isBackgroundBusy(): boolean { return this.backgroundBusy; }
  backgroundState(): string { return this.backgroundStatus; }
  private markPushRevocation(): void {
    this.backgroundEnabled = false; this.backgroundReady = false; this.pushRevokePending = true;
    this.store?.putSync('pushEnabled', false); this.store?.putSync('pushRevokePending', true); this.store?.flushSync();
  }
  private async pushPost(path: string, body: string): Promise<string> {
    const cfg: TvNotificationConfig | null = this.config;
    if (cfg === null) { throw new Error('not configured'); }
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(cfg.endpoint + path, {
        method: http.RequestMethod.POST, header: { Authorization: 'Bearer ' + cfg.token, 'Content-Type': 'application/json' },
        extraData: body, expectDataType: http.HttpDataType.STRING,
        usingCache: false, usingProxy: false, caPath: this.caPath,
        certificatePinning: { publicKeyHash: cfg.publicKeyHash, hashAlgorithm: 'SHA-256' },
        maxRedirects: 0, connectTimeout: 5000, readTimeout: 8000, maxLimit: 512 * 1024
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new PushHttpError(response.responseCode);
      }
      return response.result;
    } finally { request.destroy(); }
  }
  private async revokePush(): Promise<boolean> {
    if (!this.pushRevokePending) { return true; }
    const body: PushRevokeRequest = { installationId: this.installationId };
    const response: PushRevocation = JSON.parse(await this.pushPost('/v1/push/revoke', JSON.stringify(body))) as PushRevocation;
    if (response.revoked !== true) { throw new Error('invalid revocation'); }
    this.pushRevokePending = false;
    this.store?.putSync('pushRevokePending', false); this.store?.flushSync();
    return true;
  }
  async setBackgroundEnabled(value: boolean): Promise<void> {
    if (this.config === null || this.store === null || this.context === null) { return; }
    if (!value) {
      const ownsBusy: boolean = !this.backgroundBusy;
      if (ownsBusy) { this.backgroundBusy = true; }
      this.pushGeneration++; this.pendingPushNonce = ''; this.pendingPushInstallation = '';
      this.markPushRevocation(); this.backgroundStatus = '后台推送已关闭，正在撤销登记'; this.changed();
      // A register already in flight may complete after this revoke. Its stale
      // completion performs a second revocation before enabling anything else.
      try { await this.revokePush(); this.backgroundStatus = '后台推送已关闭'; }
      catch (_error) { this.backgroundStatus = '本机已关闭，联网后继续撤销后台登记'; }
      if (ownsBusy) { this.backgroundBusy = false; }
      this.changed(); return;
    }
    if (this.backgroundBusy) { return; }
    const generation: number = ++this.pushGeneration;
    const scope: string = this.scope;
    this.backgroundBusy = true; this.pushRefreshAttempted = true;
    this.backgroundStatus = '正在检查后台推送'; this.changed();
    let registrationSent: boolean = false;
    try {
      await this.revokePush();
      if (!await this.enableSystemNotifications()) { throw new Error('notifications disabled'); }
      const token: string = await pushService.getToken();
      if (generation !== this.pushGeneration || scope !== this.scope) { return; }
      if (typeof token !== 'string' || token.length === 0 || token.length > 16384 || /[\u0000-\u001f]/.test(token)) {
        throw new Error('invalid push token');
      }
      registrationSent = true;
      const body: PushRegisterRequest = {
        installationId: this.installationId, pushToken: token, previewMode: 'full', scope
      };
      const registered: PushRegistration = JSON.parse(await this.pushPost('/v1/push/register', JSON.stringify(body))) as PushRegistration;
      if (generation !== this.pushGeneration || scope !== this.scope) {
        this.markPushRevocation(); await this.revokePush(); return;
      }
      if (registered.registered !== true || typeof registered.cloudConfigured !== 'boolean') { throw new Error('invalid registration'); }
      this.backgroundEnabled = true; this.backgroundReady = registered.cloudConfigured;
      this.store.putSync('pushEnabled', true); this.store.putSync('pushScope', scope); this.store.flushSync();
      this.backgroundStatus = registered.cloudConfigured ? '后台推送已登记，等待到达验证' : '电视已登记，等待中转配置云推送';
    } catch (error) {
      if (generation === this.pushGeneration) {
        if (registrationSent) {
          // A lost HTTP response does not prove registration failed remotely.
          this.markPushRevocation();
          try { await this.revokePush(); } catch (_error) { /* Keep persistent pending revocation. */ }
        }
        const code: number = (error as BusinessError).code;
        this.backgroundReady = false; this.backgroundStatus = pushErrorText(code);
        hilog.warn(0x0016, 'TvNotifications', 'push setup failed code=%{public}d', Number.isFinite(code) ? code : -1);
      } else if (registrationSent) {
        this.markPushRevocation();
        try { await this.revokePush(); } catch (_error) { /* Retried on next foreground. */ }
      }
    } finally {
      this.backgroundBusy = false; this.changed(); void this.resolvePushClick();
    }
  }
  private async resumePush(): Promise<void> {
    if (!this.foreground || this.config === null || this.store === null || this.backgroundBusy) { return; }
    if (this.pushRevokePending) {
      try { await this.revokePush(); this.backgroundStatus = '后台推送已关闭'; }
      catch (_error) { this.backgroundStatus = '本机已关闭，联网后继续撤销后台登记'; }
      this.changed();
    }
    // getToken refreshes a previously opted-in installation once per launch.
    if (this.backgroundEnabled && !this.pushRefreshAttempted) { await this.setBackgroundEnabled(true); }
    await this.resolvePushClick();
  }
  private async resolvePushClick(): Promise<void> {
    if (this.store === null || this.config === null || !this.foreground || this.pushResolveBusy || this.backgroundBusy) { return; }
    const nonce: string = this.pendingPushNonce;
    if (nonce.length === 0) { return; }
    if (!this.backgroundEnabled || !validPushClick(nonce, this.pendingPushInstallation, this.installationId)) {
      this.pendingPushNonce = ''; this.pendingPushInstallation = ''; return;
    }
    const generation: number = this.pushGeneration; const scope: string = this.scope;
    this.pushResolveBusy = true;
    try {
      const body: PushResolveRequest = {
        installationId: this.installationId, clickNonce: nonce, scope
      };
      const resolved: PushResolution = JSON.parse(await this.pushPost('/v1/push/resolve', JSON.stringify(body))) as PushResolution;
      if (generation !== this.pushGeneration || !this.backgroundEnabled || scope !== this.scope ||
          AccountSessionCoordinator.getInstance().currentScope().ownerScopeId !== scope || nonce !== this.pendingPushNonce) { return; }
      if (resolved.scope !== scope || typeof resolved.streamId !== 'string' || resolved.streamId.length === 0 ||
          !validNotificationEvent(resolved.event, Date.now())) { throw new Error('invalid resolved event'); }
      const key: string = notificationKey(resolved.event);
      if (!this.events.some((item: TvNotificationEvent): boolean => notificationKey(item) === key)) {
        this.events.push(resolved.event); this.events = this.events.slice(-100);
      }
      if (!this.seen.some((item: SeenNotification): boolean => item.key === key)) {
        this.seen.push({ key, expiresAt: resolved.event.expiresAt }); this.seen = this.seen.slice(-10000);
      }
      // Do not advance the polling cursor: other events may not yet be fetched.
      this.save(); this.route.request(key); this.changed();
    } catch (error) {
      const code: number = (error as BusinessError).code;
      hilog.warn(0x0016, 'TvNotifications', 'push click rejected code=%{public}d', Number.isFinite(code) ? code : -1);
      if (generation === this.pushGeneration) { this.backgroundStatus = '通知验证未完成，请在收件箱查看'; this.changed(); }
    } finally {
      if (this.pendingPushNonce === nonce) { this.pendingPushNonce = ''; this.pendingPushInstallation = ''; }
      this.pushResolveBusy = false;
      if (this.pendingPushNonce.length > 0) { void this.resolvePushClick(); }
    }
  }
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
