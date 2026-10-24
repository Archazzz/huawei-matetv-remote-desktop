  @State private mateTvToolsCorner: number = 2;
  @State private mateTvToolsHorizontal: boolean = false;
  @State private mateTvMediaCorner: number = 3;
  @State private mateTvMediaHorizontal: boolean = false;

  private mateTvLoadControls(): void {
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    const tools: number = prefs.getSync('mateTvToolsCorner', 2) as number;
    const media: number = prefs.getSync('mateTvMediaCorner', 3) as number;
    this.mateTvToolsCorner = tools >= 0 && tools <= 3 ? tools : 2;
    this.mateTvMediaCorner = media >= 0 && media <= 3 ? media : 3;
    this.mateTvToolsHorizontal = prefs.getSync('mateTvToolsHorizontal', false) === true;
    this.mateTvMediaHorizontal = prefs.getSync('mateTvMediaHorizontal', false) === true;
  }

  private mateTvSaveControls(media: boolean, corner: number, horizontal: boolean): void {
    this.mateTvStopJoystick();
    if (media) {
      this.mateTvMediaCorner = corner;
      this.mateTvMediaHorizontal = horizontal;
    } else {
      this.mateTvToolsCorner = corner;
      this.mateTvToolsHorizontal = horizontal;
    }
    const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
    prefs.putSync(media ? 'mateTvMediaCorner' : 'mateTvToolsCorner', corner);
    prefs.putSync(media ? 'mateTvMediaHorizontal' : 'mateTvToolsHorizontal', horizontal);
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

  private mateTvDockWidth(media: boolean): number {
    if (media) { return this.mateTvViewCanX || this.mateTvViewCanY ? (this.mateTvMediaHorizontal ? 172 : 112) : 48; }
    const count: number = this.mateTvOnlineDisplays().length > 1 ? 3 : 2;
    return this.mateTvToolsHorizontal ? count * 58 - 10 : 48;
  }

  private mateTvDockHeight(media: boolean): number {
    if (media) { return this.mateTvViewCanX || this.mateTvViewCanY ? (this.mateTvMediaHorizontal ? 112 : 172) : 48; }
    const count: number = this.mateTvOnlineDisplays().length > 1 ? 3 : 2;
    return this.mateTvToolsHorizontal ? 48 : count * 58 - 10;
  }

  private mateTvDockX(media: boolean): number {
    const corner: number = media ? this.mateTvMediaCorner : this.mateTvToolsCorner;
    const right: boolean = corner === 1 || corner === 3;
    const inset: number = media && corner === this.mateTvToolsCorner ? this.mateTvDockWidth(false) + 16 : 0;
    return Math.max(12, right ? this.surfaceWidth - 24 - this.mateTvDockWidth(media) - inset : 24 + inset);
  }

  private mateTvDockY(media: boolean): number {
    const corner: number = media ? this.mateTvMediaCorner : this.mateTvToolsCorner;
    return corner < 2 ? 24 : Math.max(12, this.surfaceHeight - 24 - this.mateTvDockHeight(media));
  }

  @Builder
  private mateTvIcon(symbol: Resource, label: string, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol).fontSize(23).fontColor(['#EDF8F5']).hitTestBehavior(HitTestMode.None)
    }.width(48).height(48).backgroundColor('#D9192A34')
      .accessibilityText(label).onClick(action)
  }

  @Builder
  private mateTvToolIcons() {
    this.mateTvIcon($r('sys.symbol.gearshape_fill'), '设置', (): void => { this.mateTvOpenDisplay(); })
    this.mateTvIcon(this.mateTvViewMode === 'fill' ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') :
      $r('sys.symbol.arrow_up_left_and_arrow_down_right'), this.mateTvViewMode === 'fill' ? '完整画面' : '短边铺满',
      (): void => { this.mateTvSetViewFill(this.mateTvViewMode !== 'fill'); })
    if (this.mateTvOnlineDisplays().length > 1) {
      this.mateTvIcon($r('sys.symbol.rectangle_on_rectangle'), '切换到下一块显示器', (): void => { this.mateTvNextDisplay(); })
    }
  }

  @Builder
  private mateTvMediaIcons() {
    this.mateTvIcon($r('sys.symbol.mic_fill'), '文字与听写', (): void => { this.mateTvOpenText(); })
    this.mateTvViewportDock()
  }

  @Builder
  private mateTvCornerControls() {
    if (this.mateTvToolsHorizontal) {
      Row({ space: 10 }) { this.mateTvToolIcons() }
        .position({ x: this.mateTvDockX(false), y: this.mateTvDockY(false) }).zIndex(150)
    } else {
      Column({ space: 10 }) { this.mateTvToolIcons() }
        .position({ x: this.mateTvDockX(false), y: this.mateTvDockY(false) }).zIndex(150)
    }
    if (this.mateTvMediaHorizontal) {
      Row({ space: 12 }) { this.mateTvMediaIcons() }
        .position({ x: this.mateTvDockX(true), y: this.mateTvDockY(true) }).zIndex(150)
    } else {
      Column({ space: 12 }) { this.mateTvMediaIcons() }
        .position({ x: this.mateTvDockX(true), y: this.mateTvDockY(true) }).zIndex(150)
    }
  }

  @Builder
  private mateTvPositionOption(media: boolean, corner: number, title: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Rect().width(40).height(25).radius(3).fill('#15232C').stroke('#718B98').strokeWidth(1)
          Circle().width(6).height(6).fill('#A8E9D7')
            .position({ x: corner === 1 || corner === 3 ? 29 : 5, y: corner < 2 ? 4 : 15 })
        }.width(40).height(25)
        Text(title).fontSize(16).fontColor('#F4F8FA')
      }
    }.height(44).padding({ left: 12, right: 12 }).borderRadius(8)
      .backgroundColor((media ? this.mateTvMediaCorner : this.mateTvToolsCorner) === corner ? '#386D61' : '#243640')
      .accessibilityText(title + ((media ? this.mateTvMediaCorner : this.mateTvToolsCorner) === corner ? '，已选择' : ''))
      .onClick((): void => { this.mateTvSaveControls(media, corner, media ? this.mateTvMediaHorizontal : this.mateTvToolsHorizontal); })
  }

  @Builder
  private mateTvControlLayoutOptions(media: boolean) {
    Text(media ? '语音 / 画面摇杆' : '设置 / 画面 / 切屏按钮').fontSize(18).fontColor('#F4F8FA').width('100%')
    Row({ space: 10 }) {
      this.mateTvPositionOption(media, 0, '左上')
      this.mateTvPositionOption(media, 1, '右上')
      this.mateTvPositionOption(media, 2, '左下')
      this.mateTvPositionOption(media, 3, '右下')
    }
    Row({ space: 10 }) {
      this.mateTvButton(((media ? this.mateTvMediaHorizontal : this.mateTvToolsHorizontal) ? '✓ ' : '') + '● ● ●  横向',
        (): void => { this.mateTvSaveControls(media, media ? this.mateTvMediaCorner : this.mateTvToolsCorner, true); })
      this.mateTvButton((!(media ? this.mateTvMediaHorizontal : this.mateTvToolsHorizontal) ? '✓ ' : '') + '⋮  纵向',
        (): void => { this.mateTvSaveControls(media, media ? this.mateTvMediaCorner : this.mateTvToolsCorner, false); })
    }
  }
