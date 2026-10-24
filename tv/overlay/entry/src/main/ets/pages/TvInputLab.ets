import { router } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TvAudioProbe } from '../services/TvAudioProbe';

@Entry
@Component
struct TvInputLab {
  @State private events: string[] = [];
  @State private text: string = '';
  @State private count: number = 0;
  @State private audioTesting: boolean = false;
  @State private audioTestFailed: boolean = false;
  @State private testFocused: boolean = false;
  private audioProbe: TvAudioProbe = new TvAudioProbe();
  private audioGeneration: number = 0;

  private cancelAudioTest(): void {
    this.audioGeneration++;
    this.audioProbe.cancel();
    this.audioTesting = false;
  }

  onPageHide(): void { this.cancelAudioTest(); }
  aboutToDisappear(): void { this.cancelAudioTest(); }

  private async testAudio(): Promise<void> {
    if (this.audioTesting) { return; }
    const generation = ++this.audioGeneration;
    this.audioTesting = true;
    this.audioTestFailed = false;
    const result = await this.audioProbe.play();
    if (generation !== this.audioGeneration) { return; }
    this.audioTesting = false;
    this.audioTestFailed = result === 'failed';
  }

  private record(value: string): void {
    this.count++;
    this.events = [this.count.toString() + '  ' + value, ...this.events].slice(0, 8);
  }

  private recordKey(stage: string, event: KeyEvent): void {
    // Only remote-control candidates; never log text or ordinary keyboard input.
    if ([2012, 2013, 2014, 2015, 2067, 2722, 9].indexOf(event.keyCode) < 0) { return; }
    const value: string = stage + ' key=' + event.keyCode.toString() +
      ' type=' + event.type.toString() + ' device=' + event.deviceId.toString();
    this.record(value);
    hilog.info(0xD003900, 'ScreenLinkInputLab', '%{public}s', value);
  }

  build() {
    Column({ space: 20 }) {
      Row() {
        Column({ space: 8 }) {
          Text('输入设备测试').fontSize(32).fontColor('#F4F8FA')
          Text(deviceInfo.deviceType + ' · API ' + deviceInfo.sdkApiVersion.toString())
            .fontSize(18).fontColor('#B1C2CA')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.audioTesting ? '播放中…' : (this.audioTestFailed ? '重试声音' : '测试声音'))
          .fontSize(20).height(48).margin({ right: 12 }).enabled(!this.audioTesting)
          .onClick((): void => { this.testAudio(); })
        Button('返回').fontSize(22).height(52).onClick((): void => {
          this.cancelAudioTest();
          router.back();
        })
      }.width('100%')
      Row({ space: 24 }) {
        Column({ space: 16 }) {
          Text(this.testFocused ? '已聚焦 · 可测试遥控器按键' : '点击此区域，测试遥控器按键').fontSize(24).fontColor('#F4F8FA')
          Text('事件仅显示在本机，不会发送到电脑。').fontSize(18).fontColor('#B1C2CA')
        }.layoutWeight(1).height(240).backgroundColor('#243640').borderRadius(16)
          .id('ScreenLinkInputLabTarget').focusable(true).defaultFocus(true)
          .onFocus((): void => { this.testFocused = true; })
          .onBlur((): void => { this.testFocused = false; })
          .onClick((event: ClickEvent): void => {
            this.getUIContext().getFocusController().requestFocus('ScreenLinkInputLabTarget');
            this.record('click source=' + event.source.toString() + ' x=' + Math.round(event.x) + ' y=' + Math.round(event.y));
          })
          .onKeyPreIme((event: KeyEvent): boolean => {
            this.recordKey('pre', event);
            return false;
          })
          .onKeyEvent((event: KeyEvent): void => {
            this.recordKey('key', event);
          })
          .onMouse((event: MouseEvent): void => {
            if (event.action !== MouseAction.Move) {
              this.record('mouse button=' + event.button.toString() + ' action=' + event.action.toString());
            }
          })
          .parallelGesture(PanGesture().onActionEnd((event: GestureEvent): void => {
            this.record('pan x=' + Math.round(event.offsetX) + ' y=' + Math.round(event.offsetY));
          }))
        Column({ space: 8 }) {
          ForEach(this.events, (event: string) => {
            Text(event).fontSize(17).fontColor('#70E0C2').width('100%')
          }, (event: string): string => event)
        }.layoutWeight(1).height(240).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('文字与系统听写').fontSize(26).fontColor('#F4F8FA')
      Text('选中下面的输入框，使用系统键盘或语音入口。若语音键仅打开小艺且文字没有回填，此固件上的遥控器听写尚不可用。')
        .fontSize(20).fontColor('#B1C2CA')
      TextArea({ text: this.text, placeholder: '测试中文、English、标点和换行' })
        .height(130).fontSize(24).maxLength(2000)
        .onChange((value: string): void => { this.text = value; })
      Text('已输入 ' + this.text.length.toString() + ' 个字符').fontSize(18).fontColor('#B1C2CA')
    }.padding(40).width('100%').height('100%').backgroundColor('#101C25')
      .alignItems(HorizontalAlign.Start)
  }
}
