  // TV uses absolute pointer down/move/up. Mouse-shaped touch events are
  // handled only by onMouse; finger touch events are handled only by onTouch.
  private mateTvMode: boolean = deviceInfo.deviceType === 'tv';
  @State private mateTvRightClick: boolean = false;
  private mateTvButtonAt: number = 0;
  private mateTvTouchId: number = -1;
  private mateTvTouchButton: number = -1;
  private mateTvRightMouseRelease: boolean = false;
  @State private mateTvTextOpen: boolean = false;
  @State private mateTvText: string = '';
  @State private mateTvTextError: string = '';
  private mateTvTextSession: number = -1;
  private mateTvTextAttempt: number = -1;

  private mateTvObserveMouse(event: MouseEvent): boolean {
    if (!this.mateTvMode) { return false; }
    if (event.sourceTool === SourceTool.Finger) { return true; }
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
      this.sendMouseNow(point.x, point.y, this.mateTvTouchButton, true);
      hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch down button=' + this.mateTvTouchButton.toString());
      return;
    }
    if (this.mateTvTouchId < 0) { return; }
    for (let index: number = 0; index < event.changedTouches.length; index++) {
      const touch: TouchObject = event.changedTouches[index];
      if (touch.id !== this.mateTvTouchId) { continue; }
      const point: MappedPoint = this.mapInputPoint(touch.x, touch.y);
      if (event.type === TouchType.Move) {
        this.queueMouseMove(point.x, point.y);
      } else if (event.type === TouchType.Up) {
        // Flush actual movement, but never manufacture MOVE between a stationary DOWN/UP.
        this.flushMouseMove();
        this.sendMouseNow(point.x, point.y, this.mateTvTouchButton, false);
        this.mateTvTouchId = -1;
        this.mateTvTouchButton = -1;
        hilog.info(RD_DOMAIN, RD_TAG, 'MateTV touch up');
      }
      return;
    }
  }

  private mateTvClick(event: ClickEvent): void {
    if (!this.mateTvMode || this.mateTvTouchId >= 0 ||
        Date.now() - this.mateTvButtonAt < 500) { return; }
    // Fallback only for devices that emit a click without any down/up events.
    if (!this.canForwardInput('matetv-click')) { return; }
    const point: MappedPoint = this.mapInputPoint(event.x, event.y);
    if (!point.inside) { return; }
    this.discardPendingMouseMove();
    const button: number = this.mateTvRightClick ? 2 : 0;
    this.sendMouseNow(point.x, point.y, button, true);
    this.sendMouseNow(point.x, point.y, button, false);
    this.mateTvRightClick = false;
  }

  private mateTvCancelDrag(): void {
    this.discardPendingMouseMove();
    this.releaseTrackedMouseButtons('matetv-cancel');
    this.mateTvTouchId = -1;
    this.mateTvTouchButton = -1;
    this.mateTvRightMouseRelease = false;
  }

  private mateTvOpenText(): void {
    if (!this.canForwardInput('matetv-open-text')) { return; }
    this.mateTvCancelDrag();
    this.dismissKeyboard();
    this.mateTvTextSession = this.sessionId;
    this.mateTvTextAttempt = this.connectAttemptId;
    this.mateTvText = '';
    this.mateTvTextError = '';
    this.sessionInputOwner.appeared('MateTvText');
    this.mateTvTextOpen = true;
  }

  private mateTvCloseText(): void {
    this.mateTvTextOpen = false;
    this.mateTvText = '';
    this.mateTvTextError = '';
    this.mateTvTextSession = -1;
    this.mateTvTextAttempt = -1;
    this.sessionInputOwner.disappeared('MateTvText');
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
    Button(label, { type: ButtonType.Normal }).fontSize(19).height(48)
      .padding({ left: 18, right: 18 }).borderRadius(10)
      .backgroundColor('#243640').fontColor('#F4F8FA').onClick(action)
  }

  @Builder
  private mateTvToolbar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.mateTvButton('切换电脑', (): void => { this.goBack(); })
        this.mateTvButton('显示器 / 画质', (): void => { this.mateTvOpenDisplay(); })
        Button(this.mateTvRightClick ? '点选位置右击' : '右键', { type: ButtonType.Normal })
          .fontSize(19).height(48).padding({ left: 18, right: 18 }).borderRadius(10)
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
          .fontSize(20).fontColor('#FFD4B5')

      }
    }.padding(12).backgroundColor('#ED101C25').borderRadius(16)
      .position({ x: 24, y: 16 }).zIndex(100)
  }

  @Builder
  private mateTvTextPanel() {
    Column({ space: 20 }) {
      Text('输入到当前电脑').fontSize(28).fontColor('#F4F8FA')
      Text('使用键盘或系统输入法听写，检查后再输入。不会自动按回车。')
        .fontSize(20).fontColor('#B1C2CA')
      TextArea({ text: this.mateTvText, placeholder: '在这里输入文字' })
        .id('MateTvTextDraft').height(180).width('100%').fontSize(24).maxLength(8000)
        .onChange((value: string): void => { this.mateTvText = value; })
      if (this.mateTvTextError !== '') {
        Text(this.mateTvTextError).fontSize(20).fontColor('#FFD4B5')
      }
      Row({ space: 16 }) {
        this.mateTvButton('取消', (): void => { this.mateTvCloseText(); })
        this.mateTvButton('输入到电脑', (): void => { this.mateTvSubmitText(); })
      }
    }.width('76%').padding(32).backgroundColor('#192A34').borderRadius(20)
  }
