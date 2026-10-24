  @State private mateTvViewMode: LocalViewScaleMode = 'fill';
  @State private mateTvViewX: number = 50;
  @State private mateTvViewY: number = 50;
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
    this.mateTvViewX = edge.panX > 0.5 ? Math.max(0, Math.min(100,
      (1 - this.canvasTransform.panX / edge.panX) * 50)) : 50;
    this.mateTvViewY = edge.panY > 0.5 ? Math.max(0, Math.min(100,
      (1 - this.canvasTransform.panY / edge.panY) * 50)) : 50;
  }

  private mateTvSetViewFill(fill: boolean): void {
    this.mateTvCancelDrag();
    this.mateTvViewMode = fill ? 'fill' : 'fit';
    this.resetCanvasToDisplayDefault();
  }

  private mateTvSetViewNative(): void {
    this.mateTvCancelDrag();
    this.mateTvViewMode = '100';
    this.resetCanvasToDisplayDefault();
  }

  private mateTvPanViewport(horizontal: boolean, value: number): void {
    if (this.mateTvTextOpen || this.mateTvDisplayOpen || !this.connected || this.cleanupStarted || this.rustDeskDisplaySwitchState.inputBlocked) { return; }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    const edge: CanvasTransform = clampCanvasTransform({ scale: this.canvasTransform.scale,
      panX: 1e9, panY: 1e9, rotation: this.canvasTransform.rotation,
      strictContentBounds: true }, viewport);
    const fraction: number = 1 - 2 * Math.max(0, Math.min(100, value)) / 100;
    this.canvasTransform = clampCanvasTransform({ scale: this.canvasTransform.scale,
      panX: horizontal ? edge.panX * fraction : this.canvasTransform.panX,
      panY: horizontal ? this.canvasTransform.panY : edge.panY * fraction,
      rotation: this.canvasTransform.rotation, strictContentBounds: true }, viewport);
    this.refreshCanvasTransformModified(viewport);
    this.applyCanvasTransform();
  }

  @Builder
  private mateTvViewportDock() {
    if (this.mateTvViewCanX) {
      Column({ space: 0 }) {
        Row() {
          Text('左').fontSize(12).fontColor('#E6F1F4')
          Blank()
          Text('拖动圆点移动画面').fontSize(12).fontColor('#B1C2CA')
          Blank()
          Text('右').fontSize(12).fontColor('#E6F1F4')
        }.width('100%')
        Slider({ value: this.mateTvViewX, min: 0, max: 100, step: 0.1 })
          .width('100%').height(38).blockSize({ width: 24, height: 24 })
          .trackThickness(4).selectedColor('#70E0C2').blockColor('#D8FFF4')
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Click) { this.mateTvCancelDrag(); }
            this.mateTvPanViewport(true, value);
          })
      }.width(320).padding({ left: 16, right: 16, top: 7, bottom: 1 })
        .backgroundColor('#D9192A34').borderRadius(28).align(Alignment.Bottom).margin({ bottom: 16 })
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(150)
    }
    if (this.mateTvViewCanY) {
      Column({ space: 0 }) {
        Text('顶').fontSize(12).fontColor('#E6F1F4')
        Slider({ value: this.mateTvViewY, min: 0, max: 100, step: 0.1, direction: Axis.Vertical })
          .height(200).width(40).blockSize({ width: 24, height: 24 })
          .trackThickness(4).selectedColor('#70E0C2').blockColor('#D8FFF4')
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Click) { this.mateTvCancelDrag(); }
            this.mateTvPanViewport(false, value);
          })
        Text('底').fontSize(12).fontColor('#E6F1F4')
      }.width(48).padding({ top: 12, bottom: 12 })
        .backgroundColor('#D9192A34').borderRadius(26).align(Alignment.End).margin({ right: 16 })
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(150)
    }
  }
