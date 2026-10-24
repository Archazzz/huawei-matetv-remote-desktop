  @State private mateTvRemoteKeys: TvRemoteKeyProfile = defaultTvRemoteKeyProfile();
  @State private mateTvRemoteDeviceId: number = -1;
  @State private mateTvRemoteBindingStatus: string = '未绑定';
  @State private mateTvRemoteCapturing: boolean = false;
  @State private mateTvRemoteSelectedKey: number = 0;
  @State private mateTvVoiceLearning: boolean = false;
  @State private mateTvVoiceStatus: string = '未检测';
  private mateTvVoiceDown: number = -1;
  private mateTvVoiceTimer: number = -1;
  private mateTvVoiceGeneration: number = 0;
  private mateTvRemoteGestureTimer: number = -1;
  private mateTvRemoteGestureGeneration: number = 0;
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
    this.mateTvCancelRemoteKeys();
    this.mateTvCancelRemoteCapture();
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    this.mateTvRemoteKeys = parseTvRemoteKeyProfile(prefs.getSync(this.mateTvRemotePrefsKey(), '') as string);
    this.mateTvVoiceStatus = this.mateTvRemoteKeys.voiceKeyCode < 0 ? '未检测' : '已检测按键';
    this.mateTvRemoteDevicesChanged();
  }

  private mateTvSaveRemoteKeys(): void {
    this.mateTvCancelRemoteKeys();
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
    this.mateTvCancelRemoteKeys();
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
    const profile: TvRemoteKeyProfile = parseTvRemoteKeyProfile(JSON.stringify(this.mateTvRemoteKeys));
    if (fingerprint.length === 0 || fingerprint !== profile.fingerprint) { profile.voiceKeyCode = -1; }
    profile.enabled = true; profile.fingerprint = fingerprint; profile.deviceName = candidate.name;
    this.mateTvRemoteKeys = profile;
    this.mateTvVoiceStatus = profile.voiceKeyCode < 0 ? '未检测' : '已检测按键';
    this.mateTvRemoteBindingStatus = (fingerprint.length === 0 ? '仅本次连接 · ' : '已绑定 · ') + candidate.name;
    this.mateTvCancelRemoteCapture();
    this.mateTvSaveRemoteKeys();
  }

  private mateTvSetRemoteAction(index: number, gesture: number, action: string): void {
    if (index < 0 || index > 5 || (gesture === 0 ? !tvRemoteActionValid(action) : !tvRemoteGestureActionValid(action))) { return; }
    const profile: TvRemoteKeyProfile = parseTvRemoteKeyProfile(JSON.stringify(this.mateTvRemoteKeys));
    if (gesture === 0) { profile.actions[index] = action; }
    else if (gesture === 1) { profile.doubleActions[index] = action; }
    else { profile.longActions[index] = action; }
    if (index === 5 && profile.actions[5] === 'original' &&
        (profile.doubleActions[5] !== 'disabled' || profile.longActions[5] !== 'disabled')) { profile.actions[5] = 'none'; }
    this.mateTvRemoteKeys = profile;
    this.mateTvSaveRemoteKeys();
  }

  private mateTvRemoteInputActive(): boolean {
    return this.connected && this.sessionId > 0 && this.inputForwardReady &&
      !this.mateTvLeaving && !this.mateTvDisplayOpen && !this.mateTvTextOpen &&
      !this.keyboardOpen && !this.keyboardImeActive && !this.remoteKeyboardModalOwnsInput() &&
      this.remoteKeyboardForeground() && this.harmonyShortcutRemoteInputAllowed() && !this.sessionInputOwner.blocked();
  }

  private mateTvCancelRemoteKeys(): void {
    this.mateTvRemoteGestureGeneration++;
    if (this.mateTvRemoteGestureTimer >= 0) { clearTimeout(this.mateTvRemoteGestureTimer); }
    this.mateTvRemoteGestureTimer = -1;
    this.mateTvRemotePolicy.cancel();
    this.mateTvCancelVoiceLearning();
    this.mateTvCancelRemoteCapture();
  }

  private mateTvFlushRemoteGestures(): void {
    const actions: string[] = this.mateTvRemotePolicy.drain();
    for (const action of actions) {
      if (!this.mateTvRemoteInputActive()) { this.mateTvCancelRemoteKeys(); return; }
      this.mateTvRunRemoteAction(action);
    }
  }

  private mateTvScheduleRemoteGestures(): void {
    if (!this.mateTvRemotePolicy.hasPending() || this.mateTvRemoteGestureTimer >= 0) { return; }
    const generation: number = this.mateTvRemoteGestureGeneration;
    this.mateTvRemoteGestureTimer = setTimeout((): void => {
      if (generation !== this.mateTvRemoteGestureGeneration) { return; }
      this.mateTvRemoteGestureTimer = -1;
      const active: boolean = this.mateTvRemoteInputActive();
      this.mateTvRemotePolicy.advance(Date.now(), active, this.mateTvRemoteDeviceId, this.mateTvRemoteKeys);
      if (!active) { this.mateTvCancelRemoteKeys(); return; }
      this.mateTvFlushRemoteGestures();
      this.mateTvScheduleRemoteGestures();
    }, 20);
  }

  private mateTvCancelVoiceLearning(): void {
    this.mateTvVoiceGeneration++;
    this.mateTvVoiceLearning = false; this.mateTvVoiceDown = -1;
    if (this.mateTvVoiceTimer >= 0) { clearTimeout(this.mateTvVoiceTimer); }
    this.mateTvVoiceTimer = -1;
  }

  private mateTvStartVoiceLearning(): void {
    this.mateTvCancelVoiceLearning();
    if (this.mateTvRemoteDeviceId < 0) { this.mateTvVoiceStatus = '请先绑定遥控器'; return; }
    this.mateTvVoiceLearning = true;
    this.mateTvVoiceStatus = '按下并松开语音键';
    const generation: number = this.mateTvVoiceGeneration;
    this.mateTvVoiceTimer = setTimeout((): void => {
      if (generation !== this.mateTvVoiceGeneration) { return; }
      this.mateTvCancelVoiceLearning();
      this.mateTvVoiceStatus = '未收到完整按键事件，可能由系统接管';
    }, 15000);
    this.getUIContext().getFocusController().requestFocus('MateTvVoiceLearning');
  }

  private mateTvLearnVoiceKey(event: KeyEvent): boolean {
    if (!this.mateTvVoiceLearning || !this.mateTvDisplayOpen || event.deviceId !== this.mateTvRemoteDeviceId ||
        !tvRemoteVoiceCandidate(event.keyCode)) { return false; }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) { return false; }
    event.stopPropagation();
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV voice learning code=%{public}d type=%{public}d', event.keyCode, event.type);
    if (event.type === KeyType.Down) { this.mateTvVoiceDown = event.keyCode; return true; }
    if (this.mateTvVoiceDown !== event.keyCode) { return true; }
    const profile: TvRemoteKeyProfile = parseTvRemoteKeyProfile(JSON.stringify(this.mateTvRemoteKeys));
    profile.voiceKeyCode = event.keyCode;
    this.mateTvRemoteKeys = profile;
    this.mateTvVoiceStatus = '已检测按键';
    this.mateTvSaveRemoteKeys();
    return true;
  }

  private mateTvRemoteGestureOptions(gesture: number): TvRemoteActionChoice[] {
    const choices: TvRemoteActionChoice[] = TV_REMOTE_KEY_ACTIONS.filter((item: TvRemoteActionChoice): boolean =>
      gesture === 0 ? (this.mateTvRemoteSelectedKey !== 5 || item.id !== 'original') : item.id !== 'original');
    if (gesture > 0) { choices.unshift({ id: 'disabled', label: '未设置' }); }
    return choices;
  }

  private mateTvRemoteGestureValue(gesture: number): string {
    return (gesture === 0 ? this.mateTvRemoteKeys.actions :
      (gesture === 1 ? this.mateTvRemoteKeys.doubleActions : this.mateTvRemoteKeys.longActions))[this.mateTvRemoteSelectedKey];
  }

  private mateTvResetRemoteKey(): void {
    const profile: TvRemoteKeyProfile = parseTvRemoteKeyProfile(JSON.stringify(this.mateTvRemoteKeys));
    profile.actions[this.mateTvRemoteSelectedKey] = 'original';
    profile.doubleActions[this.mateTvRemoteSelectedKey] = 'disabled';
    profile.longActions[this.mateTvRemoteSelectedKey] = 'disabled';
    this.mateTvRemoteKeys = profile;
    this.mateTvSaveRemoteKeys();
  }

  private mateTvRouteRemoteKey(event: KeyEvent): boolean {
    if (!this.mateTvMode || (event.type !== KeyType.Down && event.type !== KeyType.Up)) { return false; }
    const down: boolean = event.type === KeyType.Down;
    // Read-only gate: untouched physical Down/Up must reach the upstream owner exactly once.
    const active: boolean = this.mateTvRemoteInputActive();
    const decision: TvRemoteKeyDecision = this.mateTvRemotePolicy.route(event.keyCode,
      event.deviceId === undefined ? -1 : event.deviceId, down, active,
      this.mateTvRemoteDeviceId, this.mateTvRemoteKeys, Date.now());
    if (decision.consume) { event.stopPropagation(); }
    this.mateTvFlushRemoteGestures();
    if (decision.action.length > 0 && this.mateTvRemoteInputActive()) { this.mateTvRunRemoteAction(decision.action); }
    this.mateTvScheduleRemoteGestures();
    return decision.consume;
  }

  private mateTvRunRemoteAction(action: string): void {
    if (!this.mateTvRemoteInputActive()) { return; }
    if (action === 'open-settings') { this.mateTvOpenDisplay(); return; }
    if (action === 'open-dictation') { this.mateTvOpenText(); return; }
    if (action === 'toggle-fit') { this.mateTvSetViewFill(!(this.mateTvViewCanX || this.mateTvViewCanY)); return; }
    if (!this.canForwardInput('matetv-remote-key')) { return; }
    if (action.indexOf('original:') === 0) {
      const code: number = Number(action.substring(9));
      if (tvRemoteDirectionIndex(code) >= 0 || code === 2067) { this.sendVirtualKeyTap(code, '原按键'); }
      return;
    }
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
      Text('遥控器按键 · 当前电脑').fontSize(20).fontColor('#F4F8FA').width('100%')
      Text(this.mateTvRemoteBindingStatus).fontSize(15).fontColor('#70E0C2').width('100%')
      Row({ space: 12 }) {
        Button(this.mateTvRemoteCapturing ? '请按遥控器的任一方向键' : '绑定遥控器')
          .id('MateTvRemoteBinding').fontSize(16).height(42).focusable(true)
          .onClick((): void => { this.mateTvStartRemoteCapture(); })
          .onKeyEvent((event: KeyEvent): boolean => this.mateTvCaptureRemoteKey(event))
        if (this.mateTvRemoteCandidateName.length > 0) {
          Text(this.mateTvRemoteCandidateName).fontSize(15).fontColor('#B1C2CA')
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          this.mateTvButton('确认绑定', (): void => { this.mateTvConfirmRemoteBinding(); })
        }
        if (this.mateTvRemoteDeviceId >= 0) {
          this.mateTvButton('解除绑定', (): void => {
            const profile: TvRemoteKeyProfile = parseTvRemoteKeyProfile(JSON.stringify(this.mateTvRemoteKeys));
            profile.fingerprint = ''; profile.deviceName = ''; profile.voiceKeyCode = -1;
            this.mateTvRemoteKeys = profile; this.mateTvVoiceStatus = '未检测';
            this.mateTvSaveRemoteKeys();
            this.mateTvRemoteDevicesChanged();
          })
        }
      }.width('100%')
      Row({ space: 12 }) {
        Select(['↑ 上', '↓ 下', '← 左', '→ 右', '菜单键', '语音键'].map((label: string): SelectOption => ({ value: label })))
          .selected(this.mateTvRemoteSelectedKey).value(['↑ 上', '↓ 下', '← 左', '→ 右', '菜单键', '语音键'][this.mateTvRemoteSelectedKey])
          .font({ size: 18 }).layoutWeight(1)
          .onSelect((index: number): void => {
            if (index >= 0 && index < 6) { this.mateTvRemoteSelectedKey = index; this.mateTvCancelVoiceLearning(); }
          })
        this.mateTvButton('恢复本键默认', (): void => { this.mateTvResetRemoteKey(); })
      }.width('100%')
      if (this.mateTvRemoteSelectedKey === 5) {
        Row({ space: 12 }) {
          Button(this.mateTvVoiceLearning ? '请按下并松开语音键' : '检测语音键')
            .id('MateTvVoiceLearning').fontSize(16).height(42).focusable(true)
            .onClick((): void => { this.mateTvStartVoiceLearning(); })
            .onKeyEvent((event: KeyEvent): boolean => this.mateTvLearnVoiceKey(event))
          Text(this.mateTvVoiceStatus).fontSize(14).fontColor('#B1C2CA').layoutWeight(1).maxLines(2)
        }.width('100%')
      }
      ForEach(['单击', '双击', '长按'], (label: string, gesture: number): void => {
        Row({ space: 16 }) {
          Text(label).fontSize(16).fontColor('#F4F8FA').width(70)
          Select(this.mateTvRemoteGestureOptions(gesture).map((item: TvRemoteActionChoice): SelectOption => ({ value: item.label })))
            .selected(this.mateTvRemoteGestureOptions(gesture).findIndex((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteGestureValue(gesture)))
            .value(this.mateTvRemoteGestureOptions(gesture).find((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteGestureValue(gesture))?.label ?? '原按键')
            .enabled(this.mateTvRemoteSelectedKey !== 5 || this.mateTvRemoteKeys.voiceKeyCode >= 0)
            .font({ size: 16 }).onSelect((selected: number): void => {
              const choices: TvRemoteActionChoice[] = this.mateTvRemoteGestureOptions(gesture);
              if (selected >= 0 && selected < choices.length) {
                this.mateTvSetRemoteAction(this.mateTvRemoteSelectedKey, gesture, choices[selected].id);
              }
            })
        }.width('100%')
      }, (label: string): string => label)
      Text('双击间隔 0.28 秒 · 长按 0.65 秒；未设置时保留原按键响应。').fontSize(14).fontColor('#B1C2CA').width('100%')
    }.width('100%')
  }
