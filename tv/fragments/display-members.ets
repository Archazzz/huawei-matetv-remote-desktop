  @State private mateTvDisplayOpen: boolean = false;
  @State private mateTvStreamStatus: string = '';
  @State private mateTvScaleStatus: string = '';
  private mateTvStreamTimer: number = -1;

  private mateTvInitStreamDefaults(): void {
    if (!this.mateTvMode) { return; }
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    // TvHome bypasses upstream HostListPage, which normally loads these
    // preferences. Restore them on every new TV session, not only migration.
    if (prefs.getSync('mateTvStreamDefaultsV2', false) !== true) {
      prefs.putSync('rustdeskCodec', 5);
      prefs.putSync('rustdeskImageQuality', 2);
      prefs.putSync(RUSTDESK_FPS_PREF_KEY, 30);
      prefs.putSync('mateTvStreamDefaultsV2', true);
      prefs.flushSync();
    }
    const codec: number = prefs.getSync('rustdeskCodec', 5) as number;
    const quality: number = prefs.getSync('rustdeskImageQuality', 2) as number;
    this.rustdeskCodec = codec >= 0 && codec <= 5 ? codec : 5;
    this.rustdeskImageQuality = quality >= 0 && quality <= 2 ? quality : 2;
    this.rustdeskFps = normalizeRustDeskFps(prefs.getSync(RUSTDESK_FPS_PREF_KEY, 30) as number);
    AppStorage.setOrCreate('rustdeskCodec', this.rustdeskCodec);
    AppStorage.setOrCreate('rustdeskImageQuality', this.rustdeskImageQuality);
    AppStorage.setOrCreate(RUSTDESK_FPS_PREF_KEY, this.rustdeskFps);

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
    const scale: number = this.remoteLocalScalePercent();
    this.mateTvScaleStatus = scale > 0 ? '本地显示倍率 ' + scale.toString() + '%' +
      (scale > 100 ? ' · 铺满会放大像素，细字可切“原始像素”' : '') : '';
    this.rustDeskDisplayCapabilities = this.loader.getRustDeskDisplayCapabilities(this.sessionId);
  }

  private mateTvOpenDisplay(): void {
    if (this.mateTvDisplayOpen || !this.connected || this.cleanupStarted) { return; }
    this.mateTvCloseText();
    this.mateTvStopJoystick();
    this.mateTvCancelDrag();
    this.releaseRustDeskInputBeforeBlock('matetv-display');
    this.mateTvRefreshStreamStatus();
    this.sessionInputOwner.visible('MateTvDisplay', true);
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV panel open display ' + this.sessionInputOwner.debugString());
    this.mateTvDisplayOpen = true;
    if (this.mateTvStreamTimer >= 0) { clearInterval(this.mateTvStreamTimer); }
    this.mateTvStreamTimer = setInterval((): void => { this.mateTvRefreshStreamStatus(); }, 1000);
  }

  private mateTvCloseDisplay(): void {
    this.mateTvDisplayOpen = false;
    // These inline panels have no native closing animation or stacked instances.
    // Retire all of our own leases, including an earlier duplicate open.
    this.sessionInputOwner.retire('MateTvDisplay');
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV panel close display ' + this.sessionInputOwner.debugString());
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
      Text('轻扫滚动 · 停留片刻再移动可拖拽 · 短按单击').fontSize(14).fontColor('#B1C2CA')
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
          Text('画面比例').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('短边铺满', (): void => { this.mateTvSetViewFill(true); })
            this.mateTvButton('完整画面', (): void => { this.mateTvSetViewFill(false); })
            this.mateTvButton('原始像素', (): void => { this.mateTvSetViewNative(); })
          }
          Text(this.mateTvScaleStatus).fontSize(15).fontColor('#B1C2CA').width('100%')
          Text('原始像素不放大画面；超出电视的部分仍可用右下角摇杆移动。')
            .fontSize(15).fontColor('#B1C2CA').width('100%')
          Text('画质与流畅度').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('跟手 · 60 帧上限', (): void => { this.mateTvQuality(1, 60); })
            this.mateTvButton('局域网超清 · 30 帧', (): void => { this.mateTvQuality(2, 30); })
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
          Text('超清档提高编码码率请求，适合高速局域网；外网可切跟手或省带宽。静止画面码率会降低，不支持的编码会回退。')
            .fontSize(15).fontColor('#B1C2CA').width('100%')
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }.width('76%').height('82%').padding(22).backgroundColor('#192A34').borderRadius(20)
  }
