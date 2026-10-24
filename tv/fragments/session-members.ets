  // MateTV additions. Physical mouse/keyboard handling remains upstream-owned.
  private mateTvMode: boolean = deviceInfo.deviceType === 'tv';
  @State private mateTvDrag: boolean = false;
  @State private mateTvRightClick: boolean = false;
  @State private mateTvDragHeld: boolean = false;
  private mateTvMouseButtonAt: number = 0;
  private mateTvMousePressed: boolean = false;
  @State private mateTvTextOpen: boolean = false;
  @State private mateTvText: string = '';
  @State private mateTvTextError: string = '';
  private mateTvPanY: number = 0;
  private mateTvTextSession: number = -1;
  private mateTvTextAttempt: number = -1;

  private mateTvObserveMouse(event: MouseEvent): boolean {
    if (!this.mateTvMode) { return false; }
    if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      this.mateTvMouseButtonAt = Date.now();
      this.mateTvMousePressed = event.action === MouseAction.Press;
    }
    // In pickup mode a remote button need not remain physically held.
    // Regular mouse press/drag/release remains owned by the upstream handler.
    if (!this.mateTvDrag || !this.canForwardInput('matetv-mouse-drag')) { return false; }
    const point: MappedPoint = this.mapInputPoint(event.x, event.y);
    if (event.action === MouseAction.Press && event.button === MouseButton.Left) {
      if (point.inside) { this.mateTvTogglePickup(point); }
      return true;
    }
    if (event.action === MouseAction.Release && this.mapArkMouseButton(event.button) <= 0) {
      return true;
    }
    if (this.mateTvDragHeld && point.inside &&
        (event.action === MouseAction.Move || event.action === MouseAction.Hover)) {
      this.queueMouseMove(point.x, point.y);
      return true;
    }
    return false;
  }

  private mateTvTogglePickup(point: MappedPoint): void {
    this.discardPendingMouseMove();
    if (this.mateTvDragHeld) {
      this.queueMouseMove(point.x, point.y);
      this.flushMouseMove();
      this.sendMouseNow(point.x, point.y, 0, false);
      this.mateTvDragHeld = false;
    } else {
      this.sendMouseNow(point.x, point.y, 0, true);
      this.mateTvDragHeld = true;
    }
  }

  private mateTvClick(event: ClickEvent): void {
    if (!this.mateTvMode) { return; }
    // Some TV pointers produce a Mouse-source click WITHOUT onMouse down/up.
    // Deduplicate only when an actual mouse button event was observed.
    if (event.source === SourceType.Mouse && Date.now() - this.mateTvMouseButtonAt < 500) { return; }
    if (!this.canForwardInput('matetv-click')) { return; }
    const point: MappedPoint = this.mapInputPoint(event.x, event.y);
    this.logMappedInput('matetv-click', event.x, event.y, point);
    if (!point.inside) { return; }
    if (this.mateTvDrag) { this.mateTvTogglePickup(point); return; }
    this.discardPendingMouseMove();
    const button: number = this.mateTvRightClick ? 2 : 0;
    this.sendMouseNow(point.x, point.y, button, true);
    this.sendMouseNow(point.x, point.y, button, false);
    this.mateTvRightClick = false;
  }

  private mateTvPanStart(event: GestureEvent): void {
    if (!this.mateTvMode || this.mateTvMousePressed ||
        !this.canForwardInput('matetv-pan-start')) { return; }
    this.mateTvPanY = event.offsetY;
    if (this.mateTvDrag && !this.mateTvDragHeld && event.fingerList.length > 0) {
      // Pan recognition starts after the threshold: anchor DOWN to the original press.
      const x: number = event.fingerList[0].localX - event.offsetX;
      const y: number = event.fingerList[0].localY - event.offsetY;
      const point: MappedPoint = this.mapInputPoint(x, y);
      if (point.inside) {
        this.discardPendingMouseMove();
        this.gesturePanActive = true;
        this.sendMouseNow(point.x, point.y, 0, true);
      }
    }
  }

  private mateTvPanUpdate(event: GestureEvent): void {
    if (!this.mateTvMode || this.mateTvMousePressed ||
        !this.canForwardInput('matetv-pan')) { return; }
    if (this.mateTvDrag) {
      if ((this.gesturePanActive || this.mateTvDragHeld) && event.fingerList.length > 0) {
        const point: MappedPoint = this.mapInputPoint(event.fingerList[0].localX, event.fingerList[0].localY);
        if (point.inside) { this.queueMouseMove(point.x, point.y); }
      }
    } else {
      const delta: number = event.offsetY - this.mateTvPanY;
      if (Math.abs(delta) >= 8) { this.sendTouchPadWheel(delta); this.mateTvPanY = event.offsetY; }
    }
  }

  private mateTvPanEnd(_event: GestureEvent): void {
    if (!this.mateTvMode) { return; }
    if (this.gesturePanActive) { this.mateTvCancelDrag(); }
    this.mateTvPanY = 0;
  }

  private mateTvCancelDrag(): void {
    if ((this.gesturePanActive || this.mateTvDragHeld) && this.sessionId > 0) {
      this.flushMouseMove();
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
    }
    this.gesturePanActive = false;
    this.mateTvDragHeld = false;
    this.mateTvMousePressed = false;
    this.mateTvPanY = 0;
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
        this.mateTvButton(this.mateTvRightClick ? '点选位置右击' : '右键', (): void => {
          this.mateTvRightClick = !this.mateTvRightClick;
        })
        this.mateTvButton(this.mateTvDrag ? (this.mateTvDragHeld ? '拖动：点目标放下' : '拖动：点取物件') : '拖动：关', (): void => {
          this.mateTvCancelDrag(); this.mateTvDrag = !this.mateTvDrag;
        })
        this.mateTvButton('文字 / 听写', (): void => { this.mateTvOpenText(); })
        this.mateTvButton('键盘', (): void => {
          if (this.keyboardOpen) { this.dismissKeyboard(); } else { this.openKeyboard(); }
        })
        this.mateTvButton('Esc', (): void => { this.sendRemoteKeyTap(111, 'Esc'); })
      }
      if (this.rustDeskRemoteInputPermissionKnown && !this.rustDeskRemoteInputAllowed) {
        Text('只能查看：电脑端未允许键盘鼠标控制，请检查 RustDesk 当前连接的权限。')
          .fontSize(20).fontColor('#FFD4B5')
      } else if (this.mateTvDrag) {
        Text('点一下抓住物件，移动指针，再点一下放下；触控平板也可以按住滑动。')
          .fontSize(18).fontColor('#B1C2CA')
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
