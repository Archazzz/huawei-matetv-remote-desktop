  @State private mateTvDisplayOpen: boolean = false;
  @State private mateTvSourceResolution: boolean = true;
  @State private mateTvResolutionStatus: string = '';
  @State private mateTvStreamStatus: string = '';
  @State private mateTvScaleStatus: string = '';
  private mateTvStreamTimer: number = -1;
  @State private mateTvAudioGainDb: number = 0;
  private mateTvAudioGainSession: number = 0;
  private mateTvAudioGainApplied: number = -1;

  private mateTvApplyAudioGain(): void {
    if (!this.mateTvMode || !this.connected || this.cleanupStarted || this.sessionId <= 0) { return; }
    if (this.mateTvAudioGainSession === this.sessionId &&
        this.mateTvAudioGainApplied === this.mateTvAudioGainDb) { return; }
    if (this.loader.setRemoteAudioGain(this.mateTvAudioGainDb, this.sessionId)) {
      this.mateTvAudioGainSession = this.sessionId;
      this.mateTvAudioGainApplied = this.mateTvAudioGainDb;
    }
  }

  private mateTvSetAudioGain(value: number, persist: boolean): void {
    if (!Number.isFinite(value)) { return; }
    this.mateTvAudioGainDb = Math.max(0, Math.min(60, Math.round(value / 3) * 3));
    this.mateTvApplyAudioGain();
    if (persist && this.hostId !== '') {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync('mateTvAudioGainDb:' + this.hostId, this.mateTvAudioGainDb);
      prefs.flushSync();
    }
  }

  private mateTvInitStreamDefaults(): void {
    if (!this.mateTvMode) { return; }
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    const savedGain: number = prefs.getSync('mateTvAudioGainDb:' + this.hostId, 0) as number;
    this.mateTvAudioGainDb = Number.isFinite(savedGain) ?
      Math.max(0, Math.min(60, Math.round(savedGain / 3) * 3)) : 0;
    this.mateTvAudioGainSession = 0;
    this.mateTvAudioGainApplied = -1;
    // TvHome bypasses upstream HostListPage, which normally loads these
    // preferences. Restore them on every new TV session, not only migration.
    if (prefs.getSync('mateTvStreamDefaultsV2', false) !== true) {
      prefs.putSync('rustdeskCodec', 5);
      prefs.putSync('rustdeskImageQuality', 2);
      prefs.putSync(RUSTDESK_FPS_PREF_KEY, 30);
      prefs.putSync('mateTvStreamDefaultsV2', true);
      prefs.flushSync();
    }
    if (prefs.getSync('mateTvBandwidthDefaultsV3', false) !== true) {
      prefs.putSync('rustdeskImageQuality', 2);
      prefs.putSync('mateTvBandwidthDefaultsV3', true);
      prefs.flushSync();
    }
    if (prefs.getSync('mateTvFpsDefaultsV4', false) !== true) {
      prefs.putSync(RUSTDESK_FPS_PREF_KEY, 60);
      prefs.putSync('mateTvFpsDefaultsV4', true);
      prefs.flushSync();
    }
    this.mateTvSourceResolution = prefs.getSync('mateTvSourceResolution', true) === true;
    rdpnapi.setMateTvSourceResolution(this.mateTvSourceResolution);
    const codec: number = prefs.getSync('rustdeskCodec', 5) as number;
    const quality: number = prefs.getSync('rustdeskImageQuality', 2) as number;
    this.rustdeskCodec = codec >= 0 && codec <= 5 ? codec : 5;
    this.rustdeskImageQuality = quality >= 0 && quality <= 2 ? quality : 2;
    this.rustdeskFps = normalizeRustDeskFps(prefs.getSync(RUSTDESK_FPS_PREF_KEY, 30) as number);
    AppStorage.setOrCreate('rustdeskCodec', this.rustdeskCodec);
    AppStorage.setOrCreate('rustdeskImageQuality', this.rustdeskImageQuality);
    AppStorage.setOrCreate(RUSTDESK_FPS_PREF_KEY, this.rustdeskFps);
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV hardware video capabilities ' + JSON.stringify(rdpnapi.getHardwareVideoDecoderCapabilities()));

  }

  private mateTvSetSourceResolution(source: boolean): void {
    if (!rdpnapi.setMateTvSourceResolution(source)) { return; }
    this.mateTvSourceResolution = source;
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    prefs.putSync('mateTvSourceResolution', source);
    prefs.flushSync();
  }

  private mateTvRefreshStreamStatus(): void {
    if (!this.connected || this.sessionId <= 0) { return; }
    const stats: RustDeskDiagnosticsSnapshot = this.loader.getSessionDiagnostics(this.sessionId);
    if (stats.sessionId !== this.sessionId || !stats.sessionActive) { return; }
    this.mateTvResolutionStatus = '电脑回传 ' + stats.width.toString() + ' × ' + stats.height.toString();
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
    this.mateTvCloseText(false);
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

  @Builder
  private mateTvDisplayPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('设置').fontSize(24).fontColor('#F4F8FA').layoutWeight(1)
        this.mateTvButton('完成', (): void => { this.mateTvCloseDisplay(); })
      }.width('100%')
      Text('轻扫滚动 · 停留后移动拖拽 · 静止长按松开右键').fontSize(14).fontColor('#B1C2CA')
      if (this.rustDeskRemoteInputPermissionKnown && !this.rustDeskRemoteInputAllowed) {
        Text('只能查看：电脑端未允许键盘鼠标控制').fontSize(15).fontColor('#FFD4B5')
      }
      Text(this.mateTvStreamStatus).fontSize(16).fontColor('#70E0C2').width('100%')
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('远程声音').fontSize(20).fontColor('#F4F8FA').layoutWeight(1)
            Text(this.mateTvAudioGainDb === 0 ? '原始音量' : '+' + this.mateTvAudioGainDb.toString() + ' dB')
              .fontSize(16).fontColor('#70E0C2')
          }.width('100%')
          Slider({ value: this.mateTvAudioGainDb, min: 0, max: 60, step: 3 })
            .width('100%').selectedColor('#70E0C2').blockColor('#D6F5ED')
            .accessibilityText('远程声音增益')
            .onChange((value: number, mode: SliderChangeMode): void => {
              this.mateTvSetAudioGain(value, mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
            })
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
          Text('分辨率').fontSize(20).fontColor('#F4F8FA').width('100%')
          Text(this.mateTvResolutionStatus).fontSize(16).fontColor('#70E0C2').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton((this.mateTvSourceResolution ? '✓ ' : '') + '与电脑一致', (): void => { this.mateTvSetSourceResolution(true); })
            this.mateTvButton((!this.mateTvSourceResolution ? '✓ ' : '') + '降低软解分辨率', (): void => { this.mateTvSetSourceResolution(false); })
          }
          Text('原画保留电脑像素，最多约 829 万像素。软解吃力时可降低分辨率；不会更改电脑显示设置。')
            .fontSize(14).fontColor('#B1C2CA').width('100%')
          Text('画面比例').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('短边铺满', (): void => { this.mateTvSetViewFill(true); })
            this.mateTvButton('完整画面', (): void => { this.mateTvSetViewFill(false); })
            this.mateTvButton('原始像素', (): void => { this.mateTvSetViewNative(); })
          }
          Text(this.mateTvScaleStatus).fontSize(15).fontColor('#B1C2CA').width('100%')
          Text('原始像素不放大画面；超出电视的部分可用画面摇杆移动。')
            .fontSize(15).fontColor('#B1C2CA').width('100%')
          Text('码率策略').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton((this.rustdeskImageQuality === 2 ? '✓ ' : '') + '不设固定码率上限', (): void => { this.setRustDeskImageQualityPref(2); })
            this.mateTvButton((this.rustdeskImageQuality === 1 ? '✓ ' : '') + '均衡', (): void => { this.setRustDeskImageQualityPref(1); })
            this.mateTvButton((this.rustdeskImageQuality === 0 ? '✓ ' : '') + '省带宽', (): void => { this.setRustDeskImageQualityPref(0); })
          }
          Text('高带宽模式优先保留细节，实际码率随画面和网络自适应。当前电脑端不提供指定 Mbps 的硬上限。')
            .fontSize(14).fontColor('#B1C2CA').width('100%')
          Text('帧率上限').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton((this.rustdeskFps === 30 ? '✓ ' : '') + '30 帧', (): void => { this.setRustDeskFpsPref(30); })
            this.mateTvButton((this.rustdeskFps === 60 ? '✓ ' : '') + '60 帧', (): void => { this.setRustDeskFpsPref(60); })
            this.mateTvButton((this.rustdeskFps === 120 ? '✓ ' : '') + '120 帧', (): void => { this.setRustDeskFpsPref(120); })
          }
          Text('实际帧率受电脑、视频源和电视能力影响。高分辨率 VP9 软解最多请求 60 帧，积压时自动降帧；120 帧不会为低帧率视频补帧。')
            .fontSize(14).fontColor('#B1C2CA').width('100%')
          Text('角落按钮布局').fontSize(20).fontColor('#F4F8FA').width('100%')
          this.mateTvControlLayoutOptions()
          Text('编码').fontSize(20).fontColor('#F4F8FA').width('100%')
          Row({ space: 12 }) {
            this.mateTvButton('H.265 优先', (): void => { this.setRustDeskCodecPref(5); })
            this.mateTvButton('H.264 优先', (): void => { this.setRustDeskCodecPref(4); })
            this.mateTvButton('VP9 兼容', (): void => { this.setRustDeskCodecPref(2); })
          }
          Text('优先使用 H.265 硬件解码；不支持时自动回退兼容编码。')
            .fontSize(15).fontColor('#B1C2CA').width('100%')
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }.width('76%').height('82%').padding(22).backgroundColor('#192A34').borderRadius(20)
  }
