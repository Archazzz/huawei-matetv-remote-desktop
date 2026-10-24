  @State private mateTvControlsCorner: number = 2;
  @State private mateTvControlsHorizontal: boolean = false;
  @State private mateTvControlsWidth: number = 0;
  @State private mateTvControlsHeight: number = 0;

  private mateTvMeasureControlsRoot(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) { return; }
    // The remote canvas narrows for dictation and its upstream dimensions are
    // non-reactive. Corner chrome belongs to the page, not that canvas.
    this.mateTvControlsWidth = width;
    this.mateTvControlsHeight = height;
  }

  private mateTvLoadControls(): void {
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    // Merge the old two docks at the user's previous function-button position.
    const corner: number = prefs.getSync('mateTvControlsCorner', prefs.getSync('mateTvToolsCorner', 2)) as number;
    this.mateTvControlsCorner = Number.isInteger(corner) && corner >= 0 && corner <= 3 ? corner : 2;
    this.mateTvControlsHorizontal = prefs.getSync('mateTvControlsHorizontal', prefs.getSync('mateTvToolsHorizontal', false)) === true;
  }

  private mateTvSaveControls(corner: number, horizontal: boolean): void {
    this.mateTvStopJoystick();
    this.mateTvControlsCorner = corner;
    this.mateTvControlsHorizontal = horizontal;
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    prefs.putSync('mateTvControlsCorner', corner);
    prefs.putSync('mateTvControlsHorizontal', horizontal);
    prefs.flushSync();
  }

  private mateTvOnlineDisplays(): RustDeskDisplayInfo[] {
    return this.rustDeskDisplayCapabilities.displays.filter((screen: RustDeskDisplayInfo): boolean => screen.online);
  }

  private mateTvNextDisplay(): void {
    if (this.rustDeskDisplaySwitchState.inputBlocked || !this.connected || this.cleanupStarted) { return; }
    const screens: RustDeskDisplayInfo[] = this.mateTvOnlineDisplays();
    if (screens.length < 2) { return; }
    const current: number = screens.findIndex((screen: RustDeskDisplayInfo): boolean =>
      screen.display === this.rustDeskDisplayCapabilities.currentDisplay);
    this.mateTvStopJoystick();
    this.mateTvCancelDrag();
    this.selectRustDeskDisplay(screens[(current + 1) % screens.length]);
  }

  private mateTvControlLabels(): string[] {
    const labels: string[] = ['设置'];
    if (this.mateTvViewHasAlternatives) { labels.push(this.mateTvViewCanX || this.mateTvViewCanY ? '缩小' : '放大'); }
    if (this.mateTvOnlineDisplays().length > 1) { labels.push('切屏'); }
    labels.push('听写');
    if (this.mateTvViewCanX || this.mateTvViewCanY) { labels.push('摇杆'); }
    return labels;
  }

  private mateTvDockLength(): number {
    const count: number = this.mateTvSmallLabels().length;
    return count * 48 + (count - 1) * 10;
  }

  private mateTvDockWidth(): number {
    return this.mateTvControlsHorizontal ? this.mateTvDockLength() : 48;
  }

  private mateTvDockHeight(): number {
    return this.mateTvControlsHorizontal ? 48 : this.mateTvDockLength();
  }

  private mateTvDockX(): number {
    return this.mateTvControlsCorner % 2 === 1 ? Math.max(12, this.mateTvControlsWidth - 24 - this.mateTvDockWidth()) : 24;
  }

  private mateTvDockY(): number {
    return this.mateTvControlsCorner < 2 ? 24 : Math.max(12, this.mateTvControlsHeight - 24 - this.mateTvDockHeight());
  }

  private mateTvPreviewX(): number {
    const width: number = this.mateTvControlsHorizontal ? this.mateTvSmallLabels().length * 48 - 6 : 42;
    return this.mateTvControlsCorner % 2 === 1 ? 352 - width : 8;
  }

  private mateTvPreviewY(): number {
    const height: number = this.mateTvControlsHorizontal ? 24 : this.mateTvSmallLabels().length * 30 - 6;
    return this.mateTvControlsCorner < 2 ? 8 : 164 - height;
  }

  private mateTvSmallLabels(): string[] {
    return this.mateTvControlLabels().filter((label: string): boolean => label !== '摇杆');
  }

  private mateTvDockJoystickX(): number {
    if (this.mateTvControlsHorizontal) {
      return this.mateTvControlsCorner % 2 === 1 ? this.mateTvControlsWidth - 24 - 112 : 24;
    }
    return this.mateTvControlsCorner % 2 === 1 ? this.mateTvDockX() - 124 : this.mateTvDockX() + 60;
  }

  private mateTvDockJoystickY(): number {
    if (!this.mateTvControlsHorizontal) {
      return this.mateTvControlsCorner < 2 ? 24 : this.mateTvControlsHeight - 24 - 112;
    }
    return this.mateTvControlsCorner < 2 ? this.mateTvDockY() + 60 : this.mateTvDockY() - 124;
  }

  private mateTvPreviewJoystickX(): number {
    if (this.mateTvControlsHorizontal) { return this.mateTvControlsCorner % 2 === 1 ? 322 : 8; }
    return this.mateTvControlsCorner % 2 === 1 ? this.mateTvPreviewX() - 36 : this.mateTvPreviewX() + 48;
  }

  private mateTvPreviewJoystickY(): number {
    if (!this.mateTvControlsHorizontal) { return this.mateTvControlsCorner < 2 ? 8 : 134; }
    return this.mateTvControlsCorner < 2 ? this.mateTvPreviewY() + 30 : this.mateTvPreviewY() - 36;
  }

  @Builder
  private mateTvIcon(symbol: Resource, label: string, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol).fontSize(23).fontColor(['#EDF8F5']).hitTestBehavior(HitTestMode.None)
    }.width(48).height(48).backgroundColor('#D9192A34')
      .accessibilityText(label).onClick(action)
  }

  @Builder
  private mateTvControlIcons() {
    this.mateTvIcon($r('sys.symbol.gearshape_fill'), '设置', (): void => { this.mateTvOpenDisplay(); })
    if (this.mateTvViewHasAlternatives) {
      this.mateTvIcon(this.mateTvViewCanX || this.mateTvViewCanY ? $r('sys.symbol.minus_magnifyingglass') :
        $r('sys.symbol.plus_magnifyingglass'), this.mateTvViewCanX || this.mateTvViewCanY ? '缩小到完整画面' : '放大到短边铺满',
        (): void => { this.mateTvSetViewFill(!(this.mateTvViewCanX || this.mateTvViewCanY)); })
    }
    if (this.mateTvOnlineDisplays().length > 1) {
      this.mateTvIcon($r('sys.symbol.rectangle_on_rectangle'), '切换到下一块显示器', (): void => { this.mateTvNextDisplay(); })
    }
    this.mateTvIcon($r('sys.symbol.mic_fill'), '文字与听写', (): void => { this.mateTvOpenText(); })
  }

  @Builder
  private mateTvCornerControls() {
    if (this.mateTvControlsHorizontal) {
      Row({ space: 10 }) { this.mateTvControlIcons() }
        .position({ x: this.mateTvDockX(), y: this.mateTvDockY() }).zIndex(150)
    } else {
      Column({ space: 10 }) { this.mateTvControlIcons() }
        .position({ x: this.mateTvDockX(), y: this.mateTvDockY() }).zIndex(150)
    }
    if (this.mateTvViewCanX || this.mateTvViewCanY) {
      Row() { this.mateTvViewportDock() }
        .width(112).height(112)
        .position({ x: this.mateTvDockJoystickX(), y: this.mateTvDockJoystickY() }).zIndex(150)
    }
  }

  @Builder
  private mateTvPositionOption(corner: number, title: string) {
    Button(title, { type: ButtonType.Normal }).fontSize(16).fontColor('#F4F8FA')
      .height(38).padding({ left: 18, right: 18 }).borderRadius(8)
      .backgroundColor(this.mateTvControlsCorner === corner ? '#386D61' : '#243640')
      .accessibilityText(title + (this.mateTvControlsCorner === corner ? '，已选择' : ''))
      .onClick((): void => { this.mateTvSaveControls(corner, this.mateTvControlsHorizontal); })
  }

  @Builder
  private mateTvDirectionOption(horizontal: boolean, title: string) {
    Button(title, { type: ButtonType.Normal }).fontSize(16).fontColor('#F4F8FA')
      .height(38).padding({ left: 18, right: 18 }).borderRadius(8)
      .backgroundColor(this.mateTvControlsHorizontal === horizontal ? '#386D61' : '#243640')
      .accessibilityText(title + (this.mateTvControlsHorizontal === horizontal ? '，已选择' : ''))
      .onClick((): void => { this.mateTvSaveControls(this.mateTvControlsCorner, horizontal); })
  }

  @Builder
  private mateTvPreviewItems() {
    ForEach(this.mateTvSmallLabels(), (label: string): void => {
      Text(label).fontSize(12).fontColor('#EDF8F5').textAlign(TextAlign.Center)
        .width(42).height(24).backgroundColor(label === '摇杆' ? '#386D61' : '#354C58').borderRadius(6)
    }, (label: string): string => label)
  }

  @Builder
  private mateTvControlLayoutOptions() {
    Row({ space: 12 }) {
      Text('位置').fontSize(16).fontColor('#B1C2CA')
      this.mateTvPositionOption(0, '左上')
      this.mateTvPositionOption(1, '右上')
      this.mateTvPositionOption(2, '左下')
      this.mateTvPositionOption(3, '右下')
    }
    Row({ space: 12 }) {
      Text('排列').fontSize(16).fontColor('#B1C2CA')
      this.mateTvDirectionOption(true, '横向')
      this.mateTvDirectionOption(false, '纵向')
    }
    Stack({ alignContent: Alignment.TopStart }) {
      Rect().width(360).height(172).radius(10).fill('#101C25').stroke('#48606A').strokeWidth(1)
      if (this.mateTvControlsHorizontal) {
        Row({ space: 6 }) { this.mateTvPreviewItems() }
          .position({ x: this.mateTvPreviewX(), y: this.mateTvPreviewY() })
      } else {
        Column({ space: 6 }) { this.mateTvPreviewItems() }
          .position({ x: this.mateTvPreviewX(), y: this.mateTvPreviewY() })
      }
      if (this.mateTvViewCanX || this.mateTvViewCanY) {
        Text('摇杆').fontSize(10).fontColor('#EDF8F5').textAlign(TextAlign.Center)
          .width(30).height(30).backgroundColor('#386D61').borderRadius(15)
          .position({ x: this.mateTvPreviewJoystickX(), y: this.mateTvPreviewJoystickY() })
      }
    }.width(360).height(172).hitTestBehavior(HitTestMode.None)
    Text('当前 ' + this.mateTvControlLabels().length.toString() + ' 个控件 · ' + this.mateTvControlLabels().join(' → '))
      .fontSize(14).fontColor('#B1C2CA').width('100%')
  }
