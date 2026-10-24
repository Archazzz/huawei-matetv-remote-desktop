  @State private mateTvDisplayOpen: boolean = false;
  @State private mateTvSettingsTab: number = 0;
  @State private mateTvAdvancedVideoOpen: boolean = false;
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
    this.mateTvCancelRemoteCapture();
    this.mateTvCancelVoiceLearning();
    this.mateTvDisplayOpen = false;
    // These inline panels have no native closing animation or stacked instances.
    // Retire all of our own leases, including an earlier duplicate open.
    this.sessionInputOwner.retire('MateTvDisplay');
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV panel close display ' + this.sessionInputOwner.debugString());
    if (this.mateTvStreamTimer >= 0) { clearInterval(this.mateTvStreamTimer); }
    this.mateTvStreamTimer = -1;
  }
