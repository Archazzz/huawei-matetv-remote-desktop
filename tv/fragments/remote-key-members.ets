  @State private mateTvRemoteKeys: TvRemoteKeyProfile = defaultTvRemoteKeyProfile();
  @State private mateTvRemoteDeviceId: number = -1;
  @State private mateTvRemoteBindingStatus: string = '未绑定';
  @State private mateTvRemoteCapturing: boolean = false;
  @State private mateTvRemoteCandidateName: string = '';
  private mateTvRemoteCandidate: TvRemoteDevice | null = null;
  private mateTvRemotePolicy: TvRemoteKeyPolicy = new TvRemoteKeyPolicy();
  private mateTvRemoteDeviceGeneration: number = 0;
  private mateTvRemoteCaptureGeneration: number = 0;
  private mateTvRemoteCaptureTimer: number = -1;

  private mateTvRemotePrefsKey(): string {
    return this.pendingHost === null ? '' : 'mateTvRemoteKeys:' +
      JSON.stringify([this.pendingHost.userId, this.pendingHost.id]);
  }

  private mateTvLoadRemoteKeys(): void {
    this.mateTvRemotePolicy.cancel();
    this.mateTvCancelRemoteCapture();
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    this.mateTvRemoteKeys = parseTvRemoteKeyProfile(prefs.getSync(this.mateTvRemotePrefsKey(), '') as string);
    this.mateTvRemoteDevicesChanged();
  }

  private mateTvSaveRemoteKeys(): void {
    this.mateTvRemotePolicy.cancel();
    const key: string = this.mateTvRemotePrefsKey();
    if (key.length === 0) { return; }
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    prefs.putSync(key, JSON.stringify(this.mateTvRemoteKeys));
    prefs.flushSync();
  }

  private mateTvRemoteDevice(info: inputDevice.InputDeviceData): TvRemoteDevice {
    return { id: info.id, name: info.name, vendor: info.vendor, product: info.product,
      uniq: info.uniq, virtual: info.isVirtual === true };
  }

  private mateTvRemoteDevicesChanged(): void {
    if (!this.mateTvMode) { return; }
    this.mateTvRemotePolicy.cancel();
    this.mateTvCancelRemoteCapture();
    this.mateTvRemoteDeviceId = -1;
    this.mateTvRemoteBindingStatus = '未绑定';
    const generation: number = ++this.mateTvRemoteDeviceGeneration;
    const fingerprint: string = this.mateTvRemoteKeys.fingerprint;
    if (fingerprint.length === 0) { return; }
    inputDevice.getDeviceList().then(async (ids: number[]): Promise<void> => {
      const devices: TvRemoteDevice[] = [];
      for (const id of ids) {
        try { devices.push(this.mateTvRemoteDevice(await inputDevice.getDeviceInfo(id))); }
        catch (_error) { /* An unavailable device cannot be selected. */ }
      }
      if (generation !== this.mateTvRemoteDeviceGeneration || this.cleanupStarted) { return; }
      this.mateTvRemoteDeviceId = resolveTvRemoteDevice(fingerprint, devices);
      this.mateTvRemoteBindingStatus = this.mateTvRemoteDeviceId < 0 ? '未绑定 · 请重新确认遥控器' :
        '已绑定 · ' + this.mateTvRemoteKeys.deviceName;
    }).catch((): void => {});
  }

  private mateTvCancelRemoteCapture(): void {
    this.mateTvRemoteCaptureGeneration++;
    this.mateTvRemoteCapturing = false;
    this.mateTvRemoteCandidate = null;
    this.mateTvRemoteCandidateName = '';
    if (this.mateTvRemoteCaptureTimer >= 0) { clearTimeout(this.mateTvRemoteCaptureTimer); }
    this.mateTvRemoteCaptureTimer = -1;
  }

  private mateTvStartRemoteCapture(): void {
    this.mateTvCancelRemoteCapture();
    this.mateTvRemoteCapturing = true;
    this.mateTvRemoteCaptureTimer = setTimeout((): void => { this.mateTvCancelRemoteCapture(); }, 15000);
    this.getUIContext().getFocusController().requestFocus('MateTvRemoteBinding');
  }

  private mateTvCaptureRemoteKey(event: KeyEvent): boolean {
    if (!this.mateTvRemoteCapturing || !this.mateTvDisplayOpen || tvRemoteDirectionIndex(event.keyCode) < 0) { return false; }
    event.stopPropagation();
    if (event.type !== KeyType.Down || this.mateTvRemoteCandidate !== null || event.deviceId === undefined || event.deviceId < 0) { return true; }
    const generation: number = ++this.mateTvRemoteCaptureGeneration;
    inputDevice.getDeviceInfo(event.deviceId).then((info: inputDevice.InputDeviceData): void => {
      if (generation !== this.mateTvRemoteCaptureGeneration || !this.mateTvRemoteCapturing || !this.mateTvDisplayOpen) { return; }
      if (info.isVirtual === true) { this.mateTvRemoteCandidateName = '请使用实体遥控器'; return; }
      this.mateTvRemoteCandidate = this.mateTvRemoteDevice(info);
      this.mateTvRemoteCandidateName = info.name;
    }).catch((): void => {
      if (generation === this.mateTvRemoteCaptureGeneration && this.mateTvRemoteCapturing) {
        this.mateTvRemoteCandidateName = '无法识别设备，请重试';
      }
    });
    return true;
  }

  private mateTvConfirmRemoteBinding(): void {
    const candidate: TvRemoteDevice | null = this.mateTvRemoteCandidate;
    if (candidate === null || !this.mateTvDisplayOpen) { return; }
    const fingerprint: string = tvRemoteDeviceFingerprint(candidate);
    this.mateTvRemoteDeviceGeneration++;
    this.mateTvRemoteDeviceId = candidate.id;
    this.mateTvRemoteKeys = { version: 1, enabled: true, fingerprint: fingerprint,
      deviceName: candidate.name, actions: this.mateTvRemoteKeys.actions.slice() };
    this.mateTvRemoteBindingStatus = (fingerprint.length === 0 ? '仅本次连接 · ' : '已绑定 · ') + candidate.name;
    this.mateTvCancelRemoteCapture();
    this.mateTvSaveRemoteKeys();
  }

  private mateTvSetRemoteAction(direction: number, action: string): void {
    if (direction < 0 || direction > 3 || !tvRemoteActionValid(action)) { return; }
    const actions: string[] = this.mateTvRemoteKeys.actions.slice();
    actions[direction] = action;
    this.mateTvRemoteKeys = { version: 1, enabled: this.mateTvRemoteKeys.enabled,
      fingerprint: this.mateTvRemoteKeys.fingerprint, deviceName: this.mateTvRemoteKeys.deviceName, actions: actions };
    this.mateTvSaveRemoteKeys();
  }

  private mateTvRouteRemoteKey(event: KeyEvent): boolean {
    if (!this.mateTvMode || (event.type !== KeyType.Down && event.type !== KeyType.Up)) { return false; }
    const down: boolean = event.type === KeyType.Down;
    const active: boolean = this.connected && this.sessionId > 0 && this.inputForwardReady &&
      !this.mateTvLeaving && !this.mateTvDisplayOpen && !this.mateTvTextOpen &&
      !this.keyboardOpen && !this.keyboardImeActive && !this.remoteKeyboardModalOwnsInput() &&
      this.remoteKeyboardForeground() && this.harmonyShortcutRemoteInputAllowed() &&
      // The mapper owns its mapped press/release state. Unmapped events continue
      // to the upstream owner, whose allowsPhysical() consumes the matching Up.
      // Checking that mutable lease here would consume an ordinary key twice.
      !this.sessionInputOwner.blocked();
    const decision: TvRemoteKeyDecision = this.mateTvRemotePolicy.route(event.keyCode,
      event.deviceId === undefined ? -1 : event.deviceId, down, active,
      this.mateTvRemoteDeviceId, this.mateTvRemoteKeys, Date.now());
    if (decision.consume) { event.stopPropagation(); }
    if (decision.action.length > 0) { this.mateTvRunRemoteAction(decision.action); }
    return decision.consume;
  }

  private mateTvRunRemoteAction(action: string): void {
    if (!this.canForwardInput('matetv-remote-key')) { return; }
    const shortcut: boolean = ['copy', 'paste', 'select-all', 'undo'].indexOf(action) >= 0;
    if (shortcut && !this.physicalKeyboardLayoutConfirmed) {
      promptAction.showToast({ message: '请先确认电脑的键盘布局', duration: 1500 });
      return;
    }
    const keys: number[] = tvRemoteActionKeys(action, this.remoteKeyboardLayoutForSession() === RemoteKeyboardLayout.MACOS);
    if (keys.length === 1) { this.sendVirtualKeyTap(keys[0], action); return; }
    if (keys.length > 1) { this.sendShortcutSequence(keys, action); return; }
    if (action === 'next-display') { this.mateTvNextDisplay(); return; }
    if (action.indexOf('pan-') === 0) {
      const viewport: CanvasViewport = this.currentCanvasViewport();
      this.mateTvMoveViewportPixels(action === 'pan-left' ? -viewport.surfaceWidth * 0.1 :
        (action === 'pan-right' ? viewport.surfaceWidth * 0.1 : 0),
        action === 'pan-up' ? -viewport.surfaceHeight * 0.1 : (action === 'pan-down' ? viewport.surfaceHeight * 0.1 : 0));
      return;
    }
    if (action === 'scroll-up' || action === 'scroll-down') {
      const wire: RemoteScrollWire = this.scrollWireForSession(false);
      const step: RemoteScrollStep = accumulateRemoteScroll(action === 'scroll-up' ? 120 : -120,
        wire, resetRemoteScrollState(), Date.now(), false);
      const src = this.toSourceSpace(this.remoteCursorX, this.remoteCursorY);
      this.sendScrollSteps(src['x'], src['y'], step.amount, wire);
    }
  }

  @Builder
  private mateTvRemoteKeySettings() {
    Column({ space: 10 }) {
      Text('遥控器方向键 · 当前电脑').fontSize(20).fontColor('#F4F8FA').width('100%')
      Text(this.mateTvRemoteBindingStatus).fontSize(15).fontColor('#70E0C2').width('100%')
      Row({ space: 12 }) {
        Button(this.mateTvRemoteCapturing ? '请按遥控器的任一方向键' : '绑定遥控器')
          .id('MateTvRemoteBinding').fontSize(16).height(42).focusable(true)
          .onClick((): void => { this.mateTvStartRemoteCapture(); })
          .onKeyEvent((event: KeyEvent): boolean => this.mateTvCaptureRemoteKey(event))
        if (this.mateTvRemoteCandidateName.length > 0) {
          Text(this.mateTvRemoteCandidateName).fontSize(15).fontColor('#B1C2CA')
          this.mateTvButton('确认绑定', (): void => { this.mateTvConfirmRemoteBinding(); })
        }
        if (this.mateTvRemoteDeviceId >= 0) {
          this.mateTvButton('解除绑定', (): void => {
            this.mateTvRemoteKeys = { version: 1, enabled: true, fingerprint: '', deviceName: '', actions: this.mateTvRemoteKeys.actions.slice() };
            this.mateTvSaveRemoteKeys();
            this.mateTvRemoteDevicesChanged();
          })
        }
      }.width('100%')
      ForEach(['↑ 上', '↓ 下', '← 左', '→ 右'], (label: string, index: number): void => {
        Row({ space: 16 }) {
          Text(label).fontSize(16).fontColor('#F4F8FA').width(70)
          Select(TV_REMOTE_KEY_ACTIONS.map((item: TvRemoteActionChoice): SelectOption => ({ value: item.label })))
            .selected(TV_REMOTE_KEY_ACTIONS.findIndex((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteKeys.actions[index]))
            .value(TV_REMOTE_KEY_ACTIONS.find((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteKeys.actions[index])?.label ?? '原方向键')
            .font({ size: 16 }).onSelect((selected: number): void => {
              if (selected >= 0 && selected < TV_REMOTE_KEY_ACTIONS.length) { this.mateTvSetRemoteAction(index, TV_REMOTE_KEY_ACTIONS[selected].id); }
            })
        }.width('100%')
      }, (label: string): string => label)
    }.width('100%')
  }
