import { TvNotificationService } from '../services/notifications/TvNotificationService';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { HostSyncService } from '../services/HostSyncService';
import { CloudStore } from '../services/CloudStore';
import { RemoteHost } from '../model/RemoteHost';
import { provisionTvComputers } from '../services/TvComputerProvisioning';

@Entry
@Component
struct TvHome {
  @StorageLink('screenLinkNotificationsRevision') @Watch('notificationChanged') private notificationRevision: number = 0;
  private visible: boolean = false;
  @State private computers: RemoteHost[] = [];
  @State private ready: boolean = false;
  @State private opening: boolean = false;
  @State private error: string = '';
  @State private editing: boolean = false;
  @State private label: string = '';
  @State private address: string = '';
  @State private port: string = '21118';
  @State private saving: boolean = false;
  @State private focusedComputer: string = '';
  private service: HostSyncService = HostSyncService.getInstance();
  private generation: number = 0;
  private navigationGeneration: number = 0;

  aboutToAppear(): void { this.visible = true; void this.refresh(); }
  onPageShow(): void { this.navigationGeneration++; this.visible = true; this.opening = false; void this.refresh(); }
  onPageHide(): void { this.visible = false; this.navigationGeneration++; }
  aboutToDisappear(): void { this.visible = false; this.generation++; this.navigationGeneration++; }

  private notificationChanged(): void {
    if (!this.visible || !this.ready || this.opening) { return; }
    const notices: TvNotificationService = TvNotificationService.getInstance();
    if (notices.routeAction('', false, false) !== 'open') { return; }
    const target: string = notices.pendingHost();
    const host: RemoteHost | undefined = this.computers.find((item: RemoteHost): boolean => item.id === target);
    if (host === undefined) { return; }
    this.openComputer(host);
    notices.consume();
  }

  private async refresh(): Promise<void> {
    const generation: number = ++this.generation;
    this.ready = false;
    try {
      const context: common.Context = getContext(this) as common.Context;
      if (!await AccountSessionCoordinator.getInstance().init(context)) {
        throw new Error('本机数据初始化失败，请重试');
      }
      await this.service.init(context);
      if (!CloudStore.getInstance().isReady()) { throw new Error('本机存储尚未就绪'); }
      if (generation !== this.generation) { return; }
      provisionTvComputers(context);
      this.computers = this.service.getAllHosts().filter((h: RemoteHost): boolean => h.protocol === 'rustdesk');
      this.ready = true;
      this.error = '';
      TvNotificationService.getInstance().initialize(context as common.UIAbilityContext);
      this.notificationChanged();
    } catch (error) {
      if (generation === this.generation) { this.error = (error as Error).message; }
    }
  }

  private saveComputer(): void {
    const endpoint: string = this.address.trim();
    const port: number = Number(this.port);
    if (!this.ready || this.saving) { return; }
    if (this.label.trim().length === 0 || endpoint.length === 0 ||
        /[\s/\\?#@]/.test(endpoint) || !/^\d+$/.test(this.port) ||
        !Number.isInteger(port) || port < 1 || port > 65535) {
      this.error = '请填写名称、IP 或主机名，以及 1–65535 的端口；地址不带 http://';
      return;
    }
    this.saving = true;
    try {
      const host: RemoteHost = new RemoteHost();
      host.id = RemoteHost.generateId();
      host.userId = AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
      host.label = this.label.trim();
      host.protocol = 'rustdesk';
      host.host = endpoint;
      host.port = port;
      host.customHostname = endpoint;
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = endpoint;
      host.rustdeskDirectPort = port;
      host.rustdeskAuthMode = 'password';
      host.rustdeskPasswordMode = 1;
      if (!this.service.addHost(host)) { throw new Error('保存失败，请检查地址或解锁本机数据'); }
      this.computers = this.service.getAllHosts().filter((h: RemoteHost): boolean => h.protocol === 'rustdesk');
      this.editing = false;
      this.label = '';
      this.address = '';
      this.port = '21118';
      this.error = '';
    } catch (error) {
      this.error = (error as Error).message;
    } finally {
      this.saving = false;
    }
  }

  private openComputer(host: RemoteHost): void {
    if (!this.ready) { return; }
    // The upstream session performs authentication and host-lock checks.
    // Never pass authenticated/preauthenticated flags from this launcher.
    this.openPage('pages/RemoteDesktop', host.id);
  }

  private openPage(url: string, hostId: string = ''): void {
    if (!this.visible || this.opening) { return; }
    this.opening = true;
    const generation: number = ++this.navigationGeneration;
    const params: Record<string, Object> = {};
    if (hostId.length > 0) { params['hostId'] = hostId; }
    router.pushUrl({ url, params }).catch((): void => {
      // A late rejection must not unlock a newer navigation after returning home.
      if (generation !== this.navigationGeneration || !this.visible) { return; }
      this.opening = false;
      this.error = '无法打开页面，请重试';
    });
  }

  @Builder
  private action(label: string, callback: () => void) {
    Button(label, { type: ButtonType.Normal })
      .fontSize(22).height(56).padding({ left: 24, right: 24 })
      .fontColor('#EAF2F3').backgroundColor('#243640').borderRadius(12)
      .onClick(callback)
  }

  private computerArt(host: RemoteHost): Resource | null {
    const name: string = host.label.toLowerCase();
    if (name.includes('windows') || /(^|[^a-z])pc([^a-z]|$)/.test(name)) { return $r('app.media.device_windows_pc'); }
    if (name.includes('book')) { return $r('app.media.device_macbook'); }
    if (name.includes('studio')) { return $r('app.media.device_mac_studio'); }
    if (name.includes('mini')) { return $r('app.media.device_mac_mini'); }
    return null;
  }

  @Builder
  private headerAction(symbol: Resource, label: string, callback: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        SymbolGlyph(symbol).fontSize(20).fontColor(['#B5DBD3']).hitTestBehavior(HitTestMode.None)
        Text(label).fontSize(17).fontColor('#EAF2F3').hitTestBehavior(HitTestMode.None)
      }.padding({ left: 16, right: 16 })
    }.height(48).backgroundColor('#243640').borderRadius(12)
      .accessibilityText(label).onClick(callback)
  }

  @Builder
  private computerCard(host: RemoteHost) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        if (this.computerArt(host) !== null) {
          Image(this.computerArt(host) as Resource).width('52%').height('100%')
            .objectFit(ImageFit.Contain).hitTestBehavior(HitTestMode.None)
        } else {
          SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(72).fontColor(['#70E0C2'])
            .width('52%').hitTestBehavior(HitTestMode.None)
        }
        Column({ space: 12 }) {
          Text(host.label).fontSize(26).fontWeight(FontWeight.Medium).fontColor('#F4F8FA')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(host.rustdeskDirectEnabled ? '直接连接' : '中继连接')
            .fontSize(15).fontColor('#AFC4CC')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding({ right: 20 })
          .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
      }.width('100%').height('100%').hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }.width('100%').height(230).backgroundColor('#182833').borderRadius(20)
      .border({ width: 2, radius: 20, color: this.focusedComputer === host.id ? '#70E0C2' : '#2A414D' }).clip(true)
      .accessibilityText(host.label).enabled(!this.opening)
      .onFocus((): void => { this.focusedComputer = host.id; })
      .onBlur((): void => { if (this.focusedComputer === host.id) { this.focusedComputer = ''; } })
      .onClick((): void => { this.openComputer(host); })
  }

  build() {
    Column({ space: 24 }) {
      Row() {
        Column({ space: 8 }) {
          Text('屏间 · ScreenLink').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#F4F8FA')
          Text('你的电脑，就在大屏上').fontSize(16).fontColor('#AFC4CC')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Row({ space: 10 }) {
          this.headerAction($r('sys.symbol.bell'), '电脑通知', (): void => { if (this.ready) { this.openPage('pages/TvNotifications'); } })
          this.headerAction($r('sys.symbol.plus'), '添加电脑', (): void => { if (this.ready) { this.editing = true; } })
          this.headerAction($r('sys.symbol.gearshape_fill'), '管理高级连接', (): void => { this.openPage('pages/HostListPage'); })
          this.headerAction($r('sys.symbol.rectangle_on_rectangle'), '输入设备测试', (): void => { this.openPage('pages/TvInputLab'); })
        }
      }.width('100%')
      if (this.error !== '') {
        Row({ space: 16 }) {
          Text(this.error).fontSize(20).fontColor('#FFD4B5').layoutWeight(1)
          this.action('重试', (): void => { void this.refresh(); })
        }.padding(16).backgroundColor('#352A25').borderRadius(12)
      }
      if (this.editing) {
        Column({ space: 16 }) {
          Text('添加电脑').fontSize(26).fontColor('#F4F8FA')
          TextInput({ text: this.label, placeholder: '名称，例如：书房电脑' })
            .height(56).fontSize(22).maxLength(60).onChange((value: string): void => { this.label = value; })
          TextInput({ text: this.address, placeholder: '电脑或家中桥接服务的 IP / 主机名' })
            .height(56).fontSize(22).maxLength(253).onChange((value: string): void => { this.address = value; })
          TextInput({ text: this.port, placeholder: '端口' }).type(InputType.Number)
            .height(56).fontSize(22).maxLength(5).onChange((value: string): void => { this.port = value; })
          Text('电脑需开启 RustDesk 的 IP 直接访问；连接时再输入密码。外网电脑请填写家中桥接地址。')
            .fontSize(18).fontColor('#B1C2CA')
          Row({ space: 16 }) {
            this.action('取消', (): void => { this.editing = false; this.error = ''; })
            Button(this.saving ? '保存中…' : '保存电脑', { type: ButtonType.Normal })
              .height(56).fontSize(22).padding({ left: 28, right: 28 }).borderRadius(12)
              .backgroundColor('#70E0C2').fontColor('#10251E').enabled(this.ready && !this.saving)
              .onClick((): void => { this.saveComputer(); })
          }
        }.width('76%').padding(28).backgroundColor('#192A34').borderRadius(16)
      } else {
        Scroll() {
          Column({ space: 16 }) {
            if (!this.ready && this.error === '') {
              Text('正在读取电脑列表…').fontSize(26).fontColor('#B1C2CA').padding(48)
            } else if (this.computers.length === 0 && this.ready) {
              Column({ space: 18 }) {
                Text('添加第一台电脑').fontSize(30).fontColor('#F4F8FA')
                Text('连接同一网络里的 Mac 或 PC，也可以通过家中桥接访问外网电脑。')
                  .fontSize(22).fontColor('#B1C2CA').textAlign(TextAlign.Center)
              }.padding(48).width('100%').backgroundColor('#192A34').borderRadius(16)
            }
            Grid() {
              ForEach(this.computers, (host: RemoteHost): void => {
                GridItem() { this.computerCard(host) }
              }, (host: RemoteHost): string => host.id)
            }.columnsTemplate('1fr 1fr').columnsGap(18).rowsGap(18)
              .width('100%').height(Math.ceil(this.computers.length / 2) * 248)

          }.width('100%')
        }.layoutWeight(1).width('100%')

      }
    }.width('100%').height('100%').padding(32).backgroundColor('#101C25')
      .alignItems(HorizontalAlign.Start)
  }
}
