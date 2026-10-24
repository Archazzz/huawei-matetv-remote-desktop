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
  @State private computers: RemoteHost[] = [];
  @State private ready: boolean = false;
  @State private error: string = '';
  @State private editing: boolean = false;
  @State private label: string = '';
  @State private address: string = '';
  @State private port: string = '21118';
  @State private saving: boolean = false;
  private service: HostSyncService = HostSyncService.getInstance();
  private generation: number = 0;

  aboutToAppear(): void { void this.refresh(); }
  onPageShow(): void { void this.refresh(); }
  aboutToDisappear(): void { this.generation++; }

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
    router.pushUrl({ url: 'pages/RemoteDesktop', params: { hostId: host.id } })
      .catch((): void => { this.error = '无法打开远程桌面，请重试'; });
  }

  @Builder
  private action(label: string, callback: () => void) {
    Button(label, { type: ButtonType.Normal })
      .fontSize(22).height(56).padding({ left: 24, right: 24 })
      .fontColor('#EAF2F3').backgroundColor('#243640').borderRadius(12)
      .onClick(callback)
  }

  build() {
    Column({ space: 24 }) {
      Row() {
        Column({ space: 8 }) {
          Text('MateTV Remote').fontSize(18).fontColor('#70E0C2')
          Text('你的电脑，就在大屏上').fontSize(36).fontWeight(FontWeight.Medium).fontColor('#F4F8FA')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.action('输入设备测试', (): void => { router.pushUrl({ url: 'pages/TvInputLab' }); })
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
            ForEach(this.computers, (host: RemoteHost) => {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 24 }) {
                  Column({ space: 8 }) {
                    Text(host.label).fontSize(28).fontColor('#F4F8FA')
                    Text(host.rustdeskDirectEnabled ? '直接连接' : '通过中继连接')
                      .fontSize(18).fontColor('#B1C2CA')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('连接').fontSize(24).fontColor('#70E0C2')
                }.padding(28).width('100%')
              }.width('100%').backgroundColor('#192A34').borderRadius(16)
                .onClick((): void => { this.openComputer(host); })
            }, (host: RemoteHost): string => host.id)
          }.width('100%')
        }.layoutWeight(1).width('100%')
        Row({ space: 16 }) {
          Button('添加电脑', { type: ButtonType.Normal }).fontSize(22).height(56)
            .padding({ left: 28, right: 28 }).borderRadius(12).fontColor('#10251E')
            .backgroundColor('#70E0C2').enabled(this.ready)
            .onClick((): void => { this.editing = true; })
          this.action('管理与高级连接', (): void => { router.pushUrl({ url: 'pages/HostListPage' }); })
          Blank()
          Text('遥控器 · 触控平板 · 蓝牙键鼠').fontSize(18).fontColor('#B1C2CA')
        }.width('100%')
      }
    }.width('100%').height('100%').padding(40).backgroundColor('#101C25')
      .alignItems(HorizontalAlign.Start)
  }
}
