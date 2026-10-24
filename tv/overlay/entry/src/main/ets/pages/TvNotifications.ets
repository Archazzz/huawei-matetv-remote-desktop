import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { TvNotificationService } from '../services/notifications/TvNotificationService';
import { TvNotificationEvent, notificationKey } from '../services/notifications/TvNotificationPolicy';

@Entry
@Component
struct TvNotifications {
  @StorageLink('screenLinkNotificationsRevision') @Watch('refresh') private revision: number = 0;
  @State private events: TvNotificationEvent[] = [];
  @State private status: string = '';
  @State private receiving: boolean = false;
  @State private permissionStatus: string = '';
  private routing: boolean = false;
  private service: TvNotificationService = TvNotificationService.getInstance();
  aboutToAppear(): void { this.service.initialize(getContext(this) as common.UIAbilityContext); this.refresh(); }
  private refresh(): void {
    this.events = this.service.inbox(); this.status = this.service.status(); this.receiving = this.service.isEnabled();
    if (!this.routing && this.service.pendingHost().length > 0) { this.routing = true; router.back(); }
  }
  private contentState(event: TvNotificationEvent): string {
    if (event.contentState === 'truncated') { return '电脑通知内容已截断'; }
    if (event.contentState === 'hidden') { return '电脑已隐藏消息预览'; }
    if (event.contentState === 'unknown') { return '内容完整性尚未确认'; }
    return '';
  }
  build() {
    Column({ space: 20 }) {
      Row({ space: 16 }) {
        Button('返回').onClick((): void => { router.back(); })
        Text('电脑通知').fontSize(30).fontColor('#F4F8FA').layoutWeight(1)
        Button(this.receiving ? '暂停接收' : '开启接收').enabled(this.service.configured())
          .onClick((): void => { this.service.setEnabled(!this.receiving); })
        Button('系统提醒').onClick(async (): Promise<void> => {
          const enabled: boolean = await this.service.enableSystemNotifications();
          this.permissionStatus = enabled ? '系统提醒已允许' : '系统提醒未获允许，仍可查看收件箱';
        })
        Button('清空').onClick((): void => { this.service.clearHistory(); })
      }.width('100%')
      Text(this.status).fontSize(18).fontColor('#AFC4CC')
      Text('目前仅在屏间前台接收；后台推送尚未接入。').fontSize(16).fontColor('#AFC4CC')
      if (this.permissionStatus.length > 0) { Text(this.permissionStatus).fontSize(16).fontColor('#AFC4CC') }
      Scroll() {
        Column({ space: 14 }) {
          if (this.events.length === 0) { Text('暂无通知').fontSize(24).fontColor('#AFC4CC').padding(48) }
          ForEach(this.events, (event: TvNotificationEvent): void => {
            Column({ space: 10 }) {
              Row() {
                Text(event.deviceName + ' · ' + event.appName).fontSize(18).fontColor('#70E0C2').layoutWeight(1)
                Button('连接电脑').onClick((): void => { this.service.click(notificationKey(event)); })
              }.width('100%')
              Text(event.title).fontSize(23).fontColor('#F4F8FA').width('100%')
              Text(event.body).fontSize(19).fontColor('#D9E5EA').width('100%').copyOption(CopyOptions.None)
              if (this.contentState(event).length > 0) { Text(this.contentState(event)).fontSize(15).fontColor('#AFC4CC') }
            }.alignItems(HorizontalAlign.Start).padding(22).backgroundColor('#192A34').borderRadius(16).width('100%')
          }, (event: TvNotificationEvent): string => notificationKey(event))
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').padding(32).backgroundColor('#101C25').alignItems(HorizontalAlign.Start)
  }
}
