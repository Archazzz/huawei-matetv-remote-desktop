  // TV finger input is classified before sending a remote mouse button.
  // A quick swipe scrolls; dwelling before moving drags; a stationary tap clicks.
  // Physical mouse input keeps the upstream native button path.
  private mateTvMode: boolean = deviceInfo.deviceType === 'tv';
  @State private mateTvRightClick: boolean = false;
  private mateTvButtonAt: number = 0;
  private mateTvPointerX: number = -1;
  private mateTvPointerY: number = -1;
  private mateTvTouchId: number = -1;
  private mateTvTraceMoves: number = 0;
  private mateTvTouchGesture: string = 'idle';
  private mateTvTouchStartedAt: number = 0;
  private mateTvTouchStartX: number = 0;
  private mateTvTouchStartY: number = 0;
  private mateTvTouchLastY: number = 0;
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
    if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV mouse boundary action=' + event.action.toString() +
        ' tool=' + event.sourceTool.toString() + ' touchActive=' + (this.mateTvTouchId >= 0).toString());
    }
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
    if (event.type === TouchType.Down) { this.mateTvTraceMoves = 0; }
    if (event.type !== TouchType.Move || this.mateTvTraceMoves++ < 3) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch boundary type=' + event.type.toString() +
        ' tool=' + event.sourceTool.toString() + ' source=' + event.source.toString() +
        ' device=' + (event.deviceId ?? -1).toString() + ' pressure=' + event.pressure +
        ' axis=' + event.axisHorizontal + ',' + event.axisVertical +
        ' points=' + event.changedTouches.map((point: TouchObject): string =>
          point.id.toString() + ':' + point.x.toFixed(1) + ',' + point.y.toFixed(1) + ':' + (point.pressure ?? -1).toString()).join(';'));
    }
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
      this.mateTvTouchGesture = 'pending';
      this.mateTvTouchStartedAt = Date.now();
      this.mateTvTouchStartX = touch.x;
      this.mateTvTouchStartY = touch.y;
      this.mateTvTouchLastY = touch.y;
      this.touchScrollState = resetRemoteScrollState();
      // Stage for every desktop platform: a swipe must never send DOWN first.
      this.stagePhysicalMouseClick(touch.x, touch.y, point.x, point.y, this.mateTvTouchButton);
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch down button=' + this.mateTvTouchButton.toString());
      return;
    }
    if (this.mateTvTouchId < 0) { return; }
    for (let index: number = 0; index < event.changedTouches.length; index++) {
      const touch: TouchObject = event.changedTouches[index];
      if (touch.id !== this.mateTvTouchId) { continue; }
      const point: MappedPoint = this.mapInputPoint(touch.x, touch.y);
      if (event.type === TouchType.Move || event.type === TouchType.Up) {
        const dx: number = touch.x - this.mateTvTouchStartX;
        const dy: number = touch.y - this.mateTvTouchStartY;
        if (this.mateTvTouchGesture === 'pending' && Math.sqrt(dx * dx + dy * dy) >= 6) {
          const elapsed: number = Date.now() - this.mateTvTouchStartedAt;
          this.mateTvTouchGesture = elapsed >= 350 ? 'drag' : 'scroll';
          hilog.info(RD_DOMAIN, RD_TAG, 'MateTV gesture=' + this.mateTvTouchGesture + ' dwellMs=' + elapsed.toString());
          if (this.mateTvTouchGesture === 'scroll') {
            // Cancel the staged click before any wheel sample. This also prevents
            // the hover stream from accidentally promoting it to a drag.
            this.clearPhysicalMouseClickTransaction();
            this.physicalMouseDownButton = -1;
          }
        }
        if (this.mateTvTouchGesture === 'drag') {
          if (!this.physicalMouseRemoteDownSent) {
            this.promotePhysicalMouseClickToDrag(touch.x, touch.y, point.x, point.y, 'matetv-dwell');
          } else {
            this.queueMouseMove(point.x, point.y);
          }
        } else if (this.mateTvTouchGesture === 'scroll') {
          this.sendTouchPadWheel(touch.y - this.mateTvTouchLastY);
        }
        // Keep the whole initial distance until a gesture crosses its dead zone.
        if (this.mateTvTouchGesture !== 'pending') { this.mateTvTouchLastY = touch.y; }
      }
      if (event.type === TouchType.Up) {
        if (this.mateTvTouchGesture === 'pending' && this.physicalMouseClickPending) {
          this.discardPendingMouseMove();
          // Classify only at release: moving after a dwell remains a left drag.
          const button: number = Date.now() - this.mateTvTouchStartedAt >= 600 ? 2 : this.mateTvTouchButton;
          this.sendMouseNow(this.physicalMousePressX, this.physicalMousePressY, button, true);
          this.sendMouseNow(this.physicalMousePressX, this.physicalMousePressY, button, false);
          hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch completed click');
        } else if (this.mateTvTouchGesture === 'drag' && this.physicalMouseRemoteDownSent) {
          this.flushMouseMove();
          this.sendMouseNow(point.x, point.y, this.mateTvTouchButton, false);
        }
        this.clearPhysicalMouseClickTransaction();
        this.physicalMouseDownButton = -1;
        this.mateTvResetTouchState();
        hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch up');
      }
      return;
    }
  }

  private mateTvActivate(event: ClickEvent): void {
    if (!this.mateTvMode) { return; }
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV activate source=' + event.source.toString());
    if (event.source === SourceType.KEY || event.source === SourceType.JOYSTICK) {
      if (this.mateTvPointerX >= 0 && this.mateTvPointerY >= 0) {
        this.mateTvClick(this.mateTvPointerX, this.mateTvPointerY);
      }
    } else {
      this.mateTvClick(event.x, event.y);
    }
  }

  private mateTvClick(localX: number, localY: number): void {
    if (!this.mateTvMode) { return; }
    if (this.mateTvTouchId >= 0) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV activate skipped active-touch');
      return;
    }
    if (Date.now() - this.mateTvButtonAt < 500) {
      // Consume only the semantic activation belonging to that raw sequence.
      this.mateTvButtonAt = 0;
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV activate skipped duplicate-raw');
      return;
    }
    // Fallback only for devices that emit a click without any down/up events.
    if (!this.canForwardInput('matetv-click')) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV activate skipped input-gate'); return;
    }
    const point: MappedPoint = this.mapInputPoint(localX, localY);
    if (!point.inside) {
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV activate skipped outside'); return;
    }
    this.discardPendingMouseMove();
    const button: number = this.mateTvRightClick ? 2 : 0;
    this.sendMouseNow(point.x, point.y, button, true);
    this.sendMouseNow(point.x, point.y, button, false);
    this.mateTvRightClick = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV tap sent click');
  }

  private mateTvResetTouchState(): void {
    this.mateTvTouchId = -1;
    this.mateTvTouchButton = -1;
    this.mateTvTouchGesture = 'idle';
    this.mateTvTouchStartedAt = 0;
    this.touchScrollState = resetRemoteScrollState();
  }

  private mateTvCancelDrag(): void {
    this.discardPendingMouseMove();
    this.releaseTrackedMouseButtons('matetv-cancel');
    this.mateTvResetTouchState();
    this.mateTvRightMouseRelease = false;
  }

  private mateTvOpenText(): void {
    if (this.mateTvTextOpen) { return; }
    this.mateTvStopJoystick();
    if (!this.canForwardInput('matetv-open-text')) { return; }
    this.mateTvCancelDrag();
    this.dismissKeyboard();
    this.mateTvTextFocusGeneration++;
    this.mateTvTextSession = this.sessionId;
    this.mateTvTextAttempt = this.connectAttemptId;
    this.mateTvText = '';
    this.mateTvTextError = '';
    this.sessionInputOwner.visible('MateTvText', true);
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
    this.sessionInputOwner.retire('MateTvText');
    hilog.info(RD_DOMAIN, RD_TAG, 'MateTV panel close text ' + this.sessionInputOwner.debugString());
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
