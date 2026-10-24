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
