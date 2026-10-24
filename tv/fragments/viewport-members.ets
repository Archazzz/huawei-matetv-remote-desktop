  @State private mateTvViewportOpen: boolean = false;
  @State private mateTvViewFill: boolean = true;
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
    this.mateTvViewFill = fill;
    this.resetCanvasToDisplayDefault();
  }

  private mateTvPanViewport(horizontal: boolean, value: number): void {
    if (!this.mateTvViewportOpen || this.mateTvTextOpen || !this.connected || this.cleanupStarted) { return; }
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

  private mateTvOpenViewport(): void {
    this.mateTvCancelDrag();
    this.releaseRustDeskInputBeforeBlock('matetv-viewport');
    this.mateTvSyncViewport(this.currentCanvasViewport());
    this.sessionInputOwner.appeared('MateTvViewport');
    this.mateTvViewportOpen = true;
  }

  private mateTvCloseViewport(): void {
    this.mateTvViewportOpen = false;
    this.sessionInputOwner.disappeared('MateTvViewport');
  }

  @Builder
  private mateTvViewportPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('移动画面').fontSize(20).fontColor('#F4F8FA').layoutWeight(1)
        this.mateTvButton('完成', (): void => { this.mateTvCloseViewport(); })
      }.width('100%')
      Row({ space: 8 }) {
        this.mateTvButton(this.mateTvViewFill ? '✓ 短边铺满' : '短边铺满', (): void => { this.mateTvSetViewFill(true); })
        this.mateTvButton(!this.mateTvViewFill ? '✓ 完整画面' : '完整画面', (): void => { this.mateTvSetViewFill(false); })
        this.mateTvButton('居中', (): void => { this.resetCanvasToDisplayDefault(); })
      }
      if (this.mateTvViewCanX) {
        Text('左 ← 画面位置 → 右').fontSize(15).fontColor('#B1C2CA')
        Slider({ value: this.mateTvViewX, min: 0, max: 100, step: 0.1 })
          .width('100%').height(36).selectedColor('#70E0C2')
          .onChange((value: number): void => { this.mateTvPanViewport(true, value); })
      }
      if (this.mateTvViewCanY) {
        Text('顶 ← 画面位置 → 底').fontSize(15).fontColor('#B1C2CA')
        Slider({ value: this.mateTvViewY, min: 0, max: 100, step: 0.1 })
          .width('100%').height(36).selectedColor('#70E0C2')
          .onChange((value: number): void => { this.mateTvPanViewport(false, value); })
      }
      Text(this.mateTvViewCanX || this.mateTvViewCanY ?
        '拖动滑块查看边缘，点“完成”继续控制电脑。' : '当前画面已全部显示。')
        .fontSize(14).fontColor('#B1C2CA')
    }.width(470).padding(16).backgroundColor('#F5192A34').borderRadius(14)
      .position({ x: 24, y: 78 }).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY).zIndex(150)
  }
