  // Page composition only. Session state and persistence live in display-members;
  // shared visual rules and layout primitives live in theme/ and components/.
  private mateTvSettingsTabStyle(label: string): SubTabBarStyle {
    return SubTabBarStyle.of(label)
      .labelStyle({ selectedColor: TvSettingsTokens.textAccent,
        unselectedColor: TvSettingsTokens.textSecondary,
        font: { size: TvSettingsTokens.fontControl } })
      .indicator({ color: TvSettingsTokens.textAccent });
  }

  @Builder
  private mateTvDisplayChoices() {
    ForEach(this.rustDeskDisplayCapabilities.displays, (screen: RustDeskDisplayInfo): void => {
      Button((screen.display === this.rustDeskDisplayCapabilities.currentDisplay ? '当前 · ' : '') +
        this.rustDeskDisplayLabel(screen) + '  ' + screen.width.toString() + ' × ' + screen.height.toString(),
        { type: ButtonType.Normal })
        .width('100%').height(TvSettingsTokens.controlHeight)
        .fontSize(TvSettingsTokens.fontControl).borderRadius(TvSettingsTokens.controlRadius)
        .fontColor(screen.display === this.rustDeskDisplayCapabilities.currentDisplay ?
          TvSettingsTokens.textAccent : TvSettingsTokens.textPrimary)
        .backgroundColor(TvSettingsTokens.controlBackground)
        .enabled(screen.online && !this.rustDeskDisplaySwitchState.inputBlocked)
        .onClick((): void => {
          this.mateTvCloseDisplay();
          this.selectRustDeskDisplay(screen);
        })
    }, (screen: RustDeskDisplayInfo): string => screen.display.toString())
    if (this.rustDeskDisplayCapabilities.displays.length === 0) {
      Text('正在读取显示器…').fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textSecondary)
    }
  }

  @Builder
  private mateTvResolutionChoices() {
    Select([{ value: '与电脑一致' }, { value: '降低软件解码分辨率' }])
      .selected(this.mateTvSourceResolution ? 0 : 1)
      .value(this.mateTvSourceResolution ? '与电脑一致' : '降低软件解码分辨率')
      .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .accessibilityText('回传分辨率')
      .onSelect((index: number): void => {
        if (index === 0 || index === 1) { this.mateTvSetSourceResolution(index === 0); }
      })
    Text(this.mateTvResolutionStatus).fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textAccent)
  }

  @Builder
  private mateTvViewChoices() {
    Select([{ value: '短边铺满' }, { value: '完整画面' }, { value: '原始像素' }])
      .selected(this.mateTvViewMode === 'fill' ? 0 : (this.mateTvViewMode === 'fit' ? 1 : 2))
      .value(this.mateTvViewMode === 'fill' ? '短边铺满' : (this.mateTvViewMode === 'fit' ? '完整画面' : '原始像素'))
      .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .accessibilityText('画面比例')
      .onSelect((index: number): void => {
        if (index === 0 || index === 1) { this.mateTvSetViewFill(index === 0); }
        else if (index === 2) { this.mateTvSetViewNative(); }
      })
    Text(this.mateTvScaleStatus).fontSize(TvSettingsTokens.fontCaption).fontColor(TvSettingsTokens.textSecondary)
  }

  @Builder
  private mateTvPictureSettings() {
    TvSettingsSection({ title: '显示器', content: () => { this.mateTvDisplayChoices() } })
    TvSettingsSection({ title: '回传分辨率', description: '只调整回传画面，不更改电脑的显示设置。',
      content: () => { this.mateTvResolutionChoices() } })
    TvSettingsSection({ title: '画面比例', description: '铺满时，超出电视的部分可用摇杆移动。',
      content: () => { this.mateTvViewChoices() } })
  }

  @Builder
  private mateTvQualityChoices() {
    Select([{ value: '高带宽 · 优先细节' }, { value: '均衡' }, { value: '省带宽' }])
      .selected(2 - this.rustdeskImageQuality)
      .value(this.rustdeskImageQuality === 2 ? '高带宽 · 优先细节' : (this.rustdeskImageQuality === 1 ? '均衡' : '省带宽'))
      .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .accessibilityText('码率策略')
      .onSelect((index: number): void => {
        if (index >= 0 && index <= 2) { this.setRustDeskImageQualityPref(2 - index); }
      })
  }

  @Builder
  private mateTvFrameRateChoices() {
    Select([{ value: '30 帧 / 秒' }, { value: '60 帧 / 秒' }, { value: '120 帧 / 秒' }])
      .selected(this.rustdeskFps === 30 ? 0 : (this.rustdeskFps === 60 ? 1 : 2))
      .value(this.rustdeskFps.toString() + ' 帧 / 秒')
      .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .accessibilityText('帧率上限')
      .onSelect((index: number): void => {
        if (index >= 0 && index <= 2) { this.setRustDeskFpsPref([30, 60, 120][index]); }
      })
  }

  @Builder
  private mateTvCodecChoices() {
    Select([{ value: 'H.265 优先' }, { value: 'H.264 优先' }, { value: 'VP9 兼容' }, { value: '自动 / 其他' }])
      .selected(this.rustdeskCodec === 5 ? 0 : (this.rustdeskCodec === 4 ? 1 : (this.rustdeskCodec === 2 ? 2 : 3)))
      .value(this.rustdeskCodec === 5 ? 'H.265 优先' :
        (this.rustdeskCodec === 4 ? 'H.264 优先' : (this.rustdeskCodec === 2 ? 'VP9 兼容' : '自动 / 其他')))
      .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .accessibilityText('编码偏好')
      .onSelect((index: number): void => {
        if (index >= 0 && index <= 3) { this.setRustDeskCodecPref([5, 4, 2, 0][index]); }
      })
  }

  @Builder
  private mateTvVideoSettings() {
    TvSettingsSection({ title: '码率策略', description: '高带宽模式不设固定码率上限，实际码率随画面自适应。',
      content: () => { this.mateTvQualityChoices() } })
    TvSettingsSection({ title: '帧率上限', description: '这是传输目标；实际流畅度仍取决于视频源、电脑和电视。',
      content: () => { this.mateTvFrameRateChoices() } })
    Button(this.mateTvAdvancedVideoOpen ? '收起高级选项' : '高级选项 · 编码与连接状态', { type: ButtonType.Normal })
      .fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textPrimary)
      .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
      .borderRadius(TvSettingsTokens.controlRadius)
      .onClick((): void => { this.mateTvAdvancedVideoOpen = !this.mateTvAdvancedVideoOpen; })
    if (this.mateTvAdvancedVideoOpen) {
      TvSettingsSection({ title: '编码', description: '优先硬件解码；不支持时自动回退。',
        content: () => { this.mateTvCodecChoices() } })
      TvSettingsSection({ title: '当前连接', content: () => {
        Text(this.mateTvStreamStatus).fontSize(TvSettingsTokens.fontBody)
          .fontColor(TvSettingsTokens.textAccent).width('100%')
      } })
    }
  }

  @Builder
  private mateTvAudioChoices() {
    Row() {
      Text('声音增益').fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textPrimary).layoutWeight(1)
      Text(this.mateTvAudioGainDb === 0 ? '原始音量' : '+' + this.mateTvAudioGainDb.toString() + ' dB')
        .fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textAccent)
    }.width('100%')
    Slider({ value: this.mateTvAudioGainDb, min: 0, max: 60, step: 3 })
      .width('100%').selectedColor(TvSettingsTokens.textAccent).blockColor(TvSettingsTokens.controlThumb)
      .accessibilityText('远程声音增益')
      .onChange((value: number, mode: SliderChangeMode): void => {
        this.mateTvSetAudioGain(value, mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
      })
    Button('恢复原始音量', { type: ButtonType.Normal })
      .fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textPrimary)
      .height(TvSettingsTokens.controlHeight).backgroundColor(TvSettingsTokens.controlBackground)
      .borderRadius(TvSettingsTokens.controlRadius)
      .onClick((): void => { this.mateTvSetAudioGain(0, true); })
  }

  @Builder
  private mateTvAudioSettings() {
    TvSettingsSection({ title: '电视播放音量', description: '只调整这台电脑传来的声音，并为它单独保存。',
      content: () => { this.mateTvAudioChoices() } })
  }

  @Builder
  private mateTvDisplayPanel() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Row() {
        Text('设置').fontSize(TvSettingsTokens.fontTitle).fontColor(TvSettingsTokens.textPrimary).layoutWeight(1)
        Button('完成', { type: ButtonType.Normal })
          .fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textPrimary)
          .backgroundColor(TvSettingsTokens.controlBackground).height(TvSettingsTokens.controlHeight)
          .padding({ left: TvSettingsTokens.spaceXl, right: TvSettingsTokens.spaceXl })
          .borderRadius(TvSettingsTokens.controlRadius)
          .onClick((): void => { this.mateTvCloseDisplay(); })
      }.width('100%')
      if (this.rustDeskRemoteInputPermissionKnown && !this.rustDeskRemoteInputAllowed) {
        Text('只能查看：电脑端未允许键盘鼠标控制')
          .fontSize(TvSettingsTokens.fontCaption).fontColor(TvSettingsTokens.textWarning)
      }
      Tabs({ barPosition: BarPosition.Start, index: this.mateTvSettingsTab }) {
        TabContent() {
          TvSettingsPane({ content: () => { this.mateTvPictureSettings() } })
        }.tabBar(this.mateTvSettingsTabStyle('画面'))
        TabContent() {
          TvSettingsPane({ content: () => { this.mateTvVideoSettings() } })
        }.tabBar(this.mateTvSettingsTabStyle('画质'))
        TabContent() {
          TvSettingsPane({ content: () => { this.mateTvAudioSettings() } })
        }.tabBar(this.mateTvSettingsTabStyle('声音'))
        TabContent() {
          TvSettingsPane({ content: () => { this.mateTvRemoteKeySettings() } })
        }.tabBar(this.mateTvSettingsTabStyle('遥控器'))
        TabContent() {
          TvSettingsPane({ content: () => {
            TvSettingsSection({ title: '角落控件', content: () => { this.mateTvControlLayoutOptions() } })
          } })
        }.tabBar(this.mateTvSettingsTabStyle('界面'))
      }.layoutWeight(1).width('100%').barMode(BarMode.Fixed).barHeight(TvSettingsTokens.tabHeight)
        .scrollable(false)
        .onChange((index: number): void => {
          this.mateTvCancelRemoteCapture();
          this.mateTvCancelVoiceLearning();
          this.mateTvSettingsTab = index;
        })
    }.width(TvSettingsTokens.panelWidth).height(TvSettingsTokens.panelHeight)
      .padding(TvSettingsTokens.panelPadding).backgroundColor(TvSettingsTokens.panelBackground)
      .borderRadius(TvSettingsTokens.panelRadius)
  }
