  // TV uses absolute pointer down/move/up. Mouse-shaped touch events are
  // handled only by onMouse; finger touch events are handled only by onTouch.
  private mateTvMode: boolean = deviceInfo.deviceType === 'tv';
  @State private mateTvRightClick: boolean = false;
  private mateTvButtonAt: number = 0;
  private mateTvPointerX: number = -1;
  private mateTvPointerY: number = -1;
  private mateTvTouchId: number = -1;
  private mateTvTouchButton: number = -1;
  private mateTvRightMouseRelease: boolean = false;
  @State private mateTvTextOpen: boolean = false;
  @State private mateTvText: string = '';
  @State private mateTvTextError: string = '';
  private mateTvTextSession: number = -1;
  private mateTvTextAttempt: number = -1;
  private mateTvTextFocusGeneration: number = 0;
  private mateTvTextAvoidMode: KeyboardAvoidMode | null = null;

  private mateTvObserveMouse(event: MouseEvent): boolean {
    if (!this.mateTvMode) { return false; }
    this.mateTvPointerX = event.x;
    this.mateTvPointerY = event.y;
    if (event.sourceTool === SourceTool.Finger || this.mateTvTouchId >= 0) { return true; }
    if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      this.mateTvButtonAt = Date.now();
    }
    if (event.action === MouseAction.Release && this.mateTvRightMouseRelease) {
      this.mateTvRightMouseRelease = false;
      return true;
    }
    if (this.mateTvRightClick && event.action === MouseAction.Press && event.button === MouseButton.Left) {
      if (!this.canForwardInput('matetv-right-click')) { return true; }
      const target: MappedPoint = this.mapInputPoint(event.x, event.y);
      if (target.inside) {
        this.discardPendingMouseMove();
        this.sendMouseNow(target.x, target.y, 2, true);
        this.sendMouseNow(target.x, target.y, 2, false);
        this.mateTvRightClick = false;
        this.mateTvRightMouseRelease = true;
      }
      return true;
    }
    return false;
  }

  private mateTvTouch(event: TouchEvent): void {
    // ArkUI synthesizes touch from a mouse. The mouse path owns that sequence.
    if (event.sourceTool === SourceTool.MOUSE || event.source === SourceType.Mouse) { return; }
    event.stopPropagation();
    if (event.type === TouchType.Down || event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.mateTvButtonAt = Date.now();
    }
    if (event.type === TouchType.Cancel || !this.canForwardInput('matetv-touch')) {
      if (this.mateTvTouchId >= 0) { this.mateTvCancelDrag(); }
      return;
    }
    if (event.type === TouchType.Down && this.mateTvTouchId < 0) {
      if (event.changedTouches.length === 0) { return; }
      const touch: TouchObject = event.changedTouches[0];
      const point: MappedPoint = this.mapInputPoint(touch.x, touch.y);
      if (!point.inside) { return; }
      this.mateTvTouchId = touch.id;
      this.mateTvTouchButton = this.mateTvRightClick ? 2 : 0;
      this.mateTvRightClick = false;
      this.discardPendingMouseMove();
      if (shouldStageRustDeskMacPhysicalMouseClick(
        this.currentProtocolName(), this.physicalKeyboardLayout, true, this.mateTvTouchButton)) {
        this.stagePhysicalMouseClick(touch.x, touch.y, point.x, point.y, this.mateTvTouchButton);
      } else {
        this.sendMouseNow(point.x, point.y, this.mateTvTouchButton, true);
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch down button=' + this.mateTvTouchButton.toString());
      return;
    }
    if (this.mateTvTouchId < 0) { return; }
    for (let index: number = 0; index < event.changedTouches.length; index++) {
      const touch: TouchObject = event.changedTouches[index];
      if (touch.id !== this.mateTvTouchId) { continue; }
      const point: MappedPoint = this.mapInputPoint(touch.x, touch.y);
      if (event.type === TouchType.Move || event.type === TouchType.Up) {
        if (this.physicalMouseClickPending && !this.physicalMouseRemoteDownSent) {
          this.promotePhysicalMouseClickToDrag(touch.x, touch.y, point.x, point.y, 'matetv-touch');
        } else if (event.type === TouchType.Move) {
          this.queueMouseMove(point.x, point.y);
        }
      }
      if (event.type === TouchType.Up) {
        if (this.physicalMouseClickPending && !this.physicalMouseRemoteDownSent) {
          // A Mac click must be adjacent DOWN/UP at the original target.
          // Sensor jitter is not a drag; real movement promotes the held press above.
          this.discardPendingMouseMove();
          this.sendMouseNow(this.physicalMousePressX, this.physicalMousePressY, this.mateTvTouchButton, true);
          this.sendMouseNow(this.physicalMousePressX, this.physicalMousePressY, this.mateTvTouchButton, false);
          hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch completed Mac click');
        } else {
          if (this.physicalMouseClickPending && this.physicalMouseRemoteDownSent) {
            this.queueMouseMove(point.x, point.y);
          }
          this.flushMouseMove();
          this.sendMouseNow(point.x, point.y, this.mateTvTouchButton, false);
        }
        this.clearPhysicalMouseClickTransaction();
        this.physicalMouseDownButton = -1;
        this.mateTvTouchId = -1;
        this.mateTvTouchButton = -1;
        hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch up');
      }
      return;
    }
  }

  private mateTvTap(event: GestureEvent): void {
    if (!this.mateTvMode) { return; }
    const fingers: FingerInfo[] = event.fingerInfos ?? event.fingerList;
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV tap received points=' + fingers.length.toString());
    if (fingers.length > 0 && fingers[0] !== undefined) {
      this.mateTvClick(fingers[0].localX, fingers[0].localY);
    } else if (this.mateTvPointerX >= 0 && this.mateTvPointerY >= 0) {
      this.mateTvClick(this.mateTvPointerX, this.mateTvPointerY);
    }
  }

  private mateTvConfirmKey(event: KeyEvent): boolean {
    // The TV OK key is distinct from a physical keyboard's Enter key (2054).
    if (!this.mateTvMode || event.keyCode !== 2016 || this.mateTvDisplayOpen || this.mateTvTextOpen) { return false; }
    if (event.type === KeyType.Up && this.mateTvPointerX >= 0 && this.mateTvPointerY >= 0) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV pointer confirm key');
      this.mateTvClick(this.mateTvPointerX, this.mateTvPointerY);
    }
    return true;
  }

  private mateTvClick(localX: number, localY: number): void {
    if (!this.mateTvMode || this.mateTvTouchId >= 0 ||
        Date.now() - this.mateTvButtonAt < 500) { return; }
    // Fallback only for devices that emit a click without any down/up events.
    if (!this.canForwardInput('matetv-click')) { return; }
    const point: MappedPoint = this.mapInputPoint(localX, localY);
    if (!point.inside) { return; }
    this.discardPendingMouseMove();
    const button: number = this.mateTvRightClick ? 2 : 0;
    this.sendMouseNow(point.x, point.y, button, true);
    this.sendMouseNow(point.x, point.y, button, false);
    this.mateTvRightClick = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV tap sent click');
  }

  private mateTvCancelDrag(): void {
    this.discardPendingMouseMove();
    this.releaseTrackedMouseButtons('matetv-cancel');
    this.mateTvTouchId = -1;
    this.mateTvTouchButton = -1;
    this.mateTvRightMouseRelease = false;
  }

  private mateTvOpenText(): void {
    this.mateTvCloseViewport();
    if (!this.canForwardInput('matetv-open-text')) { return; }
    this.mateTvCancelDrag();
    this.dismissKeyboard();
    this.mateTvTextFocusGeneration++;
    this.mateTvTextSession = this.sessionId;
    this.mateTvTextAttempt = this.connectAttemptId;
    this.mateTvText = '';
    this.mateTvTextError = '';
    this.sessionInputOwner.appeared('MateTvText');
    try {
      const ui = this.getUIContext();
      this.mateTvTextAvoidMode = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (_error) {}
    this.mateTvTextOpen = true;
    this.resetCanvasToDisplayDefault();
  }

  private mateTvCloseText(): void {
    const wasOpen: boolean = this.mateTvTextOpen;
    this.mateTvTextFocusGeneration++;
    this.mateTvTextOpen = false;
    if (wasOpen && this.connected && !this.cleanupStarted) { this.resetCanvasToDisplayDefault(); }
    this.mateTvText = '';
    this.mateTvTextError = '';
    this.mateTvTextSession = -1;
    this.mateTvTextAttempt = -1;
    if (wasOpen) { void inputMethod.getController().stopInputSession().catch((): void => {}); }
    if (this.mateTvTextAvoidMode !== null) {
      try { this.getUIContext().setKeyboardAvoidMode(this.mateTvTextAvoidMode); } catch (_error) {}
      this.mateTvTextAvoidMode = null;
    }
    this.sessionInputOwner.disappeared('MateTvText');
  }

  private mateTvFocusText(): void {
    if (!this.mateTvTextOpen) { return; }
    try {
      this.getUIContext().getFocusController().requestFocus('MateTvTextDraft');
    } catch (_error) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'MateTV draft focus request unavailable');
    }
  }

  private async mateTvSetKeyboardVisible(visible: boolean): Promise<void> {
    if (!this.mateTvTextOpen) { return; }
    const generation: number = this.mateTvTextFocusGeneration;
    this.mateTvFocusText();
    try {
      const controller = inputMethod.getController();
      if (visible) { await controller.showTextInput(); } else { await controller.hideTextInput(); }
      if (!this.mateTvTextOpen || generation !== this.mateTvTextFocusGeneration) { return; }
      if (!visible) { this.mateTvFocusText(); }
      this.mateTvTextError = '';
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV system keyboard requested visible=' + visible.toString());
    } catch (_error) {
      if (this.mateTvTextOpen && generation === this.mateTvTextFocusGeneration) {
        this.mateTvTextError = '键盘状态未能切换，请直接点输入框唤起键盘。';
      }
    }
  }

  private mateTvSubmitText(): void {
    if (!this.connected || this.cleanupStarted || this.sessionId <= 0 ||
        this.sessionId !== this.mateTvTextSession || this.connectAttemptId !== this.mateTvTextAttempt) {
      this.mateTvTextError = '连接已变化，请关闭面板并重新选择输入位置';
      return;
    }
    if (this.mateTvText.length === 0) { return; }
    this.sessionInputOwner.runAction((): void => {
      // Explicit submission may pass our draft overlay, but still respects
      // lifecycle, authentication, view-only and remote permission gates.
      if (!this.canForwardInput('matetv-submit-text')) {
        this.mateTvTextError = '当前连接不允许输入，请检查连接状态和电脑控制权限';
        return;
      }
      if (!this.loader.sendTextAccepted(this.sessionId, this.mateTvText)) {
        this.mateTvTextError = '当前连接未接受文字，内容已保留。可以改用外接键盘。';
        return;
      }
      // Successful submission consumes this draft. Never replay after reconnect.
      this.mateTvCloseText();
    });
  }

  @Builder
  private mateTvButton(label: string, action: () => void) {
    Button(label, { type: ButtonType.Normal }).fontSize(16).height(38)
      .padding({ left: 14, right: 14 }).borderRadius(10)
      .backgroundColor('#243640').fontColor('#F4F8FA').onClick(action)
  }

  @Builder
  private mateTvToolbar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.mateTvButton('切换电脑', (): void => { this.goBack(); })
        this.mateTvButton('移动画面', (): void => { this.mateTvOpenViewport(); })
        this.mateTvButton('显示器 / 画质', (): void => { this.mateTvOpenDisplay(); })
        Button(this.mateTvRightClick ? '点选位置右击' : '右键', { type: ButtonType.Normal })
          .fontSize(16).height(38).padding({ left: 14, right: 14 }).borderRadius(10)
          .backgroundColor('#243640').fontColor('#F4F8FA')
          .onClick((): void => { this.mateTvRightClick = !this.mateTvRightClick; })
        this.mateTvButton('文字 / 听写', (): void => { this.mateTvOpenText(); })
        this.mateTvButton('键盘', (): void => {
          if (this.keyboardOpen) { this.dismissKeyboard(); } else { this.openKeyboard(); }
        })
        this.mateTvButton('Esc', (): void => { this.sendRemoteKeyTap(111, 'Esc'); })
      }
      if (this.rustDeskRemoteInputPermissionKnown && !this.rustDeskRemoteInputAllowed) {
        Text('只能查看：电脑端未允许键盘鼠标控制，请检查 RustDesk 当前连接的权限。')
          .fontSize(16).fontColor('#FFD4B5')

      }
    }.padding(8).backgroundColor('#ED101C25').borderRadius(12)
      .position({ x: 24, y: 16 }).zIndex(100)
  }

  @Builder
  private mateTvTextPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('输入到电脑').fontSize(20).fontColor('#F4F8FA').layoutWeight(1)
        Button('关闭', { type: ButtonType.Normal }).fontSize(15).height(32)
          .backgroundColor('#243640').fontColor('#F4F8FA').borderRadius(8)
          .onClick((): void => { this.mateTvCloseText(); })
      }.width('100%')
      Text('键盘显示时长按语音键听写，确认后输入到电脑。')
        .fontSize(15).fontColor('#B1C2CA').width('100%')
      TextArea({ text: this.mateTvText, placeholder: '输入或听写…' })
        .id('MateTvTextDraft').height(90).width('100%').fontSize(18).maxLength(8000)
        .enableKeyboardOnFocus(true)
        .onAppear((): void => { this.mateTvFocusText(); })
        .onFocus((): void => { hilog.info(RD_DOMAIN, RD_TAG, 'MateTV draft focused'); })
        .onChange((value: string): void => { this.mateTvText = value; })
      Row({ space: 10 }) {
        Button('显示键盘', { type: ButtonType.Normal }).fontSize(15).height(32)
          .backgroundColor('#243640').fontColor('#F4F8FA').borderRadius(8)
          .focusOnTouch(false)
          .onClick((): void => { void this.mateTvSetKeyboardVisible(true); })
        Button('收起键盘', { type: ButtonType.Normal }).fontSize(15).height(32)
          .backgroundColor('#243640').fontColor('#F4F8FA').borderRadius(8)
          .focusOnTouch(false)
          .onClick((): void => { void this.mateTvSetKeyboardVisible(false); })
      }
      if (this.mateTvTextError !== '') {
        Text(this.mateTvTextError).fontSize(15).fontColor('#FFD4B5').width('100%')
      }
      Button('输入到电脑', { type: ButtonType.Normal })
        .width('100%').height(38).fontSize(16).borderRadius(9)
        .backgroundColor('#386D61').fontColor('#F4F8FA').enabled(this.mateTvText.length > 0)
        .onClick((): void => { this.mateTvSubmitText(); })
      Text('不会自动按回车').fontSize(13).fontColor('#B1C2CA')
    }.width(340).constraintSize({ maxWidth: '44%' }).padding(18)
      .backgroundColor('#F5192A34').borderRadius(14).margin({ top: 16, right: 20 })
  }
