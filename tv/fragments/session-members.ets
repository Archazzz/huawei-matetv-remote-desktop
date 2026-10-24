  // MateTV additions. Physical mouse/keyboard handling remains upstream-owned.
  private mateTvMode: boolean = deviceInfo.deviceType === 'tv';
  @State private mateTvDrag: boolean = false;
  @State private mateTvRightClick: boolean = false;
  @State private mateTvTextOpen: boolean = false;
  @State private mateTvText: string = '';
  @State private mateTvTextError: string = '';
  private mateTvPanY: number = 0;
  private mateTvTextSession: number = -1;
  private mateTvTextAttempt: number = -1;

  private mateTvClick(event: ClickEvent): void {
    // onMouse already forwards physical clicks. Ignore their synthesized click.
    if (!this.mateTvMode || event.source === SourceType.Mouse ||
        !this.canForwardInput('matetv-click')) { return; }
    const point: MappedPoint = this.mapInputPoint(event.x, event.y);
    if (!point.inside) { return; }
    this.remoteCursorX = point.x;
    this.remoteCursorY = point.y;
    const button: number = this.mateTvRightClick ? 2 : 0;
    this.sendMouseNow(point.x, point.y, button, true);
    this.sendMouseNow(point.x, point.y, button, false);
    this.mateTvRightClick = false;
  }

  private mateTvPanStart(event: GestureEvent): void {
    if (!this.mateTvMode || event.source === SourceType.Mouse ||
        !this.canForwardInput('matetv-pan-start')) { return; }
    this.mateTvPanY = event.offsetY;
    if (this.mateTvDrag) { this.handleGesturePanStart(event); }
  }

  private mateTvPanUpdate(event: GestureEvent): void {
    if (!this.mateTvMode || event.source === SourceType.Mouse ||
        !this.canForwardInput('matetv-pan')) { return; }
    if (this.mateTvDrag) {
      this.handleGesturePanUpdate(event);
    } else {
      const delta: number = event.offsetY - this.mateTvPanY;
      if (Math.abs(delta) >= 8) {
        this.sendTouchPadWheel(delta);
        this.mateTvPanY = event.offsetY;
      }
    }
  }

  private mateTvPanEnd(event: GestureEvent): void {
    if (!this.mateTvMode || event.source === SourceType.Mouse) { return; }
    // End events may have an empty finger list. Release at the last mapped
    // cursor position instead of jumping to the origin.
    if (this.mateTvDrag) { this.mateTvCancelDrag(); }
    this.mateTvPanY = 0;
  }

  private mateTvCancelDrag(): void {
    if (this.gesturePanActive && this.sessionId > 0) {
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
    }
    this.gesturePanActive = false;
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
    Row({ space: 8 }) {
      this.mateTvButton('切换电脑', (): void => { this.goBack(); })
      this.mateTvButton(this.mateTvRightClick ? '点选位置右击' : '右键', (): void => {
        this.mateTvRightClick = !this.mateTvRightClick;
      })
      this.mateTvButton(this.mateTvDrag ? '拖动：开' : '拖动：关', (): void => {
        this.mateTvCancelDrag(); this.mateTvDrag = !this.mateTvDrag;
      })
      this.mateTvButton('文字 / 听写', (): void => { this.mateTvOpenText(); })
      this.mateTvButton('键盘', (): void => {
        if (this.keyboardOpen) { this.dismissKeyboard(); } else { this.openKeyboard(); }
      })
      this.mateTvButton('Esc', (): void => { this.sendRemoteKeyTap(111, 'Esc'); })
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
