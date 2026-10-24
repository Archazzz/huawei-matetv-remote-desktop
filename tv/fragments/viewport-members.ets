  @State private mateTvViewMode: LocalViewScaleMode = 'fill';
  @State private mateTvJoystickX: number = 0;
  @State private mateTvJoystickY: number = 0;
  private mateTvJoystickTimer: number = -1;
  private mateTvJoystickAt: number = 0;
  @State private mateTvViewHasAlternatives: boolean = false;
  @State private mateTvViewCanX: boolean = false;
  @State private mateTvViewCanY: boolean = false;

  private mateTvSyncViewport(viewport: CanvasViewport): void {
    if (!this.mateTvMode) { return; }
    // Ask the renderer's shared policy for its actual bounds, including rotation.
    const edge: CanvasTransform = clampCanvasTransform({ scale: this.canvasTransform.scale,
      panX: 1e9, panY: 1e9, rotation: this.canvasTransform.rotation,
      strictContentBounds: true }, viewport);
    this.mateTvViewCanX = edge.panX > 0.5;
    this.mateTvViewCanY = edge.panY > 0.5;
    const rotated: boolean = ((Math.round(this.canvasTransform.rotation ?? 0) % 4 + 4) % 4) % 2 === 1;
    const width: number = rotated ? viewport.sourceHeight : viewport.sourceWidth;
    const height: number = rotated ? viewport.sourceWidth : viewport.sourceHeight;
    // Keep the toggle in fit mode for wide/portrait sources; hide it only when
    // fit and fill are equivalent (allowing for small pixel rounding errors).
    this.mateTvViewHasAlternatives = this.mateTvViewCanX || this.mateTvViewCanY ||
      (width > 0 && height > 0 && viewport.surfaceWidth > 0 && viewport.surfaceHeight > 0 &&
        Math.abs(width / height / (viewport.surfaceWidth / viewport.surfaceHeight) - 1) > 0.01);

  }

  private mateTvSetViewFill(fill: boolean): void {
    this.mateTvStopJoystick();
    this.mateTvCancelDrag();
    this.mateTvViewMode = fill ? 'fill' : 'fit';
    this.resetCanvasToDisplayDefault();
  }

  private mateTvSetViewNative(): void {
    this.mateTvStopJoystick();
    this.mateTvCancelDrag();
    this.mateTvViewMode = '100';
    this.resetCanvasToDisplayDefault();
  }

  private mateTvMoveViewportPixels(x: number, y: number): void {
    if (this.mateTvTextOpen || this.mateTvDisplayOpen || !this.connected || this.cleanupStarted || this.rustDeskDisplaySwitchState.inputBlocked) { return; }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    this.canvasTransform = clampCanvasTransform({ scale: this.canvasTransform.scale,
      panX: this.canvasTransform.panX - x, panY: this.canvasTransform.panY - y,
      rotation: this.canvasTransform.rotation, strictContentBounds: true }, viewport);
    this.refreshCanvasTransformModified(viewport);
    this.applyCanvasTransform();
  }

  private mateTvStartJoystick(event: GestureEvent): void {
    this.mateTvStopJoystick();
    this.mateTvCancelDrag();
    this.mateTvJoystickAt = Date.now();
    this.mateTvUpdateJoystick(event);
    this.mateTvJoystickTimer = setInterval((): void => { this.mateTvTickJoystick(Date.now()); }, 20);
  }

  private mateTvUpdateJoystick(event: GestureEvent): void {
    const x: number = this.mateTvViewCanX ? event.offsetX : 0;
    const y: number = this.mateTvViewCanY ? event.offsetY : 0;
    const factor: number = Math.max(1, Math.sqrt(x * x + y * y) / 30);
    this.mateTvJoystickX = x / factor;
    this.mateTvJoystickY = y / factor;
  }

  private mateTvTickJoystick(now: number): void {
    if (this.mateTvJoystickTimer < 0) { return; }
    if (!this.connected || this.cleanupStarted || this.mateTvTextOpen || this.mateTvDisplayOpen ||
        this.rustDeskDisplaySwitchState.inputBlocked) { this.mateTvStopJoystick(); return; }
    const seconds: number = Math.max(0, Math.min(0.05, (now - this.mateTvJoystickAt) / 1000));
    this.mateTvJoystickAt = now;
    const viewport: CanvasViewport = this.currentCanvasViewport();
    // Full deflection travels about one visible screen per second. The dead
    // zone absorbs remote sensor jitter; the shared clamp owns every edge.
    const x: number = Math.abs(this.mateTvJoystickX) < 3 ? 0 : this.mateTvJoystickX / 30;
    const y: number = Math.abs(this.mateTvJoystickY) < 3 ? 0 : this.mateTvJoystickY / 30;
    if (x !== 0 || y !== 0) {
      this.mateTvMoveViewportPixels(x * viewport.surfaceWidth * seconds,
        y * viewport.surfaceHeight * seconds);
    }
  }

  private mateTvStopJoystick(): void {
    if (this.mateTvJoystickTimer >= 0) { clearInterval(this.mateTvJoystickTimer); }
    this.mateTvJoystickTimer = -1;
    this.mateTvJoystickX = 0;
    this.mateTvJoystickY = 0;
    this.mateTvJoystickAt = 0;
  }

  @Builder
  private mateTvViewportDock() {
    if (this.mateTvViewCanX || this.mateTvViewCanY) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(112).height(112).fill('#C2192A34')
          .stroke('#507786').strokeWidth(1).hitTestBehavior(HitTestMode.None)
        // Fixed vector bounds avoid font baseline offsets in the four arrows.
        Path().commands('M 7 1 L 2 6 L 7 11').width(8).height(12)
          .fill(Color.Transparent).stroke(this.mateTvViewCanX ? '#D2E5E9' : '#48606A').strokeWidth(2)
          .position({ x: 8, y: 50 }).hitTestBehavior(HitTestMode.None)
        Path().commands('M 1 1 L 6 6 L 1 11').width(8).height(12)
          .fill(Color.Transparent).stroke(this.mateTvViewCanX ? '#D2E5E9' : '#48606A').strokeWidth(2)
          .position({ x: 96, y: 50 }).hitTestBehavior(HitTestMode.None)
        Path().commands('M 1 7 L 6 2 L 11 7').width(12).height(8)
          .fill(Color.Transparent).stroke(this.mateTvViewCanY ? '#D2E5E9' : '#48606A').strokeWidth(2)
          .position({ x: 50, y: 8 }).hitTestBehavior(HitTestMode.None)
        Path().commands('M 1 1 L 6 6 L 11 1').width(12).height(8)
          .fill(Color.Transparent).stroke(this.mateTvViewCanY ? '#D2E5E9' : '#48606A').strokeWidth(2)
          .position({ x: 50, y: 96 }).hitTestBehavior(HitTestMode.None)
        Circle().width(44).height(44).fill('#A8E9D7').stroke('#EBFFF8').strokeWidth(2)
          .shadow({ radius: 5, color: '#70000000', offsetY: 2 })
          .translate({ x: this.mateTvJoystickX, y: this.mateTvJoystickY })
          .gesture(PanGesture({ fingers: 1, distance: 0 })
            .onActionStart((event: GestureEvent): void => { this.mateTvStartJoystick(event); })
            .onActionUpdate((event: GestureEvent): void => { this.mateTvUpdateJoystick(event); })
            .onActionEnd((): void => { this.mateTvStopJoystick(); })
            .onActionCancel((): void => { this.mateTvStopJoystick(); }))
      }.width(112).height(112)
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(150)
    }
  }
