  @State private mateTvDisplayOpen: boolean = false;
  @State private mateTvStreamStatus: string = '';
  private mateTvStreamTimer: number = -1;

  private mateTvInitStreamDefaults(): void {
    if (!this.mateTvMode) { return; }
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    if (prefs.getSync('mateTvStreamDefaultsV1', false) === true) { return; }
    // This Mac supports HEVC hardware encoding but not AVC encoding. Advertise
    // HEVC as well as AVC/VP9 fallbacks instead of falling back directly to VP9.
    this.rustdeskCodec = 5;
    this.rustdeskImageQuality = 1;
    this.rustdeskFps = 60;
    this.persistSessionPref('rustdeskCodec', 5);
    this.persistSessionPref('rustdeskImageQuality', 1);
    this.persistSessionPref(RUSTDESK_FPS_PREF_KEY, 60);
    prefs.putSync('mateTvStreamDefaultsV1', true);
    prefs.flushSync();
  }

  private mateTvRefreshStreamStatus(): void {
    if (!this.connected || this.sessionId <= 0) { return; }
    const stats: RustDeskDiagnosticsSnapshot = this.loader.getSessionDiagnostics(this.sessionId);
    if (stats.sessionId !== this.sessionId || !stats.sessionActive) { return; }
    const names: string[] = ['H.264', 'H.265', 'VP8', 'VP9', 'AV1'];
    const codec: string = stats.codec >= 0 && stats.codec < names.length ? names[stats.codec] : '等待编码';
    this.mateTvStreamStatus = codec + ' · ' + stats.width.toString() + '×' + stats.height.toString() +
      ' · 收到 ' + stats.receivedFps.toFixed(0) + ' 帧/秒 · 显示 ' + stats.displayFps.toFixed(0) +
      ' 帧/秒 · ' + (stats.bitrateKbps / 1000).toFixed(1) + ' Mbps · 往返 ' + stats.latencyMs.toString() + ' ms';
    this.rustDeskDisplayCapabilities = this.loader.getRustDeskDisplayCapabilities(this.sessionId);
  }

  private mateTvOpenDisplay(): void {
    this.mateTvCancelDrag();
    this.releaseRustDeskInputBeforeBlock('matetv-display');
    this.mateTvRefreshStreamStatus();
    this.sessionInputOwner.appeared('MateTvDisplay');
    this.mateTvDisplayOpen = true;
    if (this.mateTvStreamTimer >= 0) { clearInterval(this.mateTvStreamTimer); }
    this.mateTvStreamTimer = setInterval((): void => { this.mateTvRefreshStreamStatus(); }, 1000);
  }

  private mateTvCloseDisplay(): void {
    this.mateTvDisplayOpen = false;
    this.sessionInputOwner.disappeared('MateTvDisplay');
    if (this.mateTvStreamTimer >= 0) { clearInterval(this.mateTvStreamTimer); }
    this.mateTvStreamTimer = -1;
  }

  private mateTvQuality(quality: number, fps: number): void {
    this.setRustDeskImageQualityPref(quality);
    this.setRustDeskFpsPref(fps);
  }

  @Builder
  private mateTvDisplayPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('显示器与画质').fontSize(24).fontColor('#F4F8FA').layoutWeight(1)
        this.mateTvButton('完成', (): void => { this.mateTvCloseDisplay(); })
      }.width('100%')
      Text(this.mateTvStreamStatus).fontSize(16).fontColor('#70E0C2').width('100%')
      Scroll() {
        Column({ space: 14 }) {
          Text('选择显示器').fontSize(20).fontColor('#F4F8FA').width('100%')
          ForEach(this.rustDeskDisplayCapabilities.displays, (screen: RustDeskDisplayInfo): void => {
            Button((screen.display === this.rustDeskDisplayCapabilities.currentDisplay ? '✓ ' : '') +
              this.rustDeskDisplayLabel(screen) + '  ' + screen.width.toString() + ' × ' + screen.height.toString(),
              { type: ButtonType.Normal })
              .width('100%').height(46).fontSize(19).borderRadius(10)
              .fontColor('#F4F8FA').backgroundColor('#243640')
              .enabled(screen.online && !this.rustDeskDisplaySwitchState.inputBlocked)
              .onClick((): void => {
                this.mateTvCloseDisplay();
                this.selectRustDeskDisplay(screen);
              })
          }, (screen: RustDeskDisplayInfo): string => screen.display.toString())
          if (this.rustDeskDisplayCapabilities.displays.length === 0) {
            Text('正在等待电脑提供显示器列表…').fontSize(20).fontColor('#B1C2CA')
          }
          Text('画质与流畅度').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('跟手 · 60 帧上限', (): void => { this.mateTvQuality(1, 60); })
            this.mateTvButton('清晰 · 30 帧上限', (): void => { this.mateTvQuality(2, 30); })
            this.mateTvButton('省带宽 · 30 帧上限', (): void => { this.mateTvQuality(0, 30); })
          }
          Text('当前偏好：' + rustDeskQualityName(this.rustdeskImageQuality) + ' · ' +
            (this.rustdeskImageQuality === 2 ? '30' : this.rustdeskFps.toString()) + ' 帧上限')
            .fontSize(16).fontColor('#B1C2CA').width('100%')
          Text('编码').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('H.265 优先', (): void => { this.setRustDeskCodecPref(5); })
            this.mateTvButton('H.264 优先', (): void => { this.setRustDeskCodecPref(4); })
            this.mateTvButton('VP9 兼容', (): void => { this.setRustDeskCodecPref(2); })
          }
          Text('帧率是上限；静止画面帧率和实际码率会降低。电脑不支持所选编码时会回退。')
            .fontSize(15).fontColor('#B1C2CA').width('100%')
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }.width('76%').height('82%').padding(22).backgroundColor('#192A34').borderRadius(20)
  }
