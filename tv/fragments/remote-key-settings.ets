  @Builder
  private mateTvRemoteSettingsButton(label: string, action: () => void) {
    Button(label, { type: ButtonType.Normal })
      .fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textPrimary)
      .height(TvSettingsTokens.controlHeight).borderRadius(TvSettingsTokens.controlRadius)
      .padding({ left: TvSettingsTokens.spaceLg, right: TvSettingsTokens.spaceLg })
      .backgroundColor(TvSettingsTokens.controlBackground).onClick(action)
  }

  @Builder
  private mateTvRemoteDeviceSettings() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Text(this.mateTvRemoteBindingStatus)
        .fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textAccent)
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: TvSettingsTokens.spaceMd }) {
        Button(this.mateTvRemoteCapturing ? '请按菜单键或方向键' : '绑定遥控器', { type: ButtonType.Normal })
          .id('MateTvRemoteBinding').focusable(true)
          .fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textPrimary)
          .height(TvSettingsTokens.controlHeight).borderRadius(TvSettingsTokens.controlRadius)
          .padding({ left: TvSettingsTokens.spaceLg, right: TvSettingsTokens.spaceLg })
          .backgroundColor(TvSettingsTokens.controlBackground)
          .onClick((): void => { this.mateTvStartRemoteCapture(); })
          .onKeyEvent((event: KeyEvent): boolean => this.mateTvCaptureRemoteKey(event))
        if (this.mateTvRemoteDeviceId >= 0) {
          this.mateTvRemoteSettingsButton('解除绑定', (): void => { this.mateTvUnbindRemoteKeys(); })
        }
      }.width('100%')
      if (this.mateTvRemoteCandidateName.length > 0) {
        Row({ space: TvSettingsTokens.spaceMd }) {
          Text(this.mateTvRemoteCandidateName)
            .fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textSecondary)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          this.mateTvRemoteSettingsButton('确认绑定', (): void => { this.mateTvConfirmRemoteBinding(); })
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private mateTvRemoteVoiceSettings() {
    Column({ space: TvSettingsTokens.spaceSm }) {
      Row({ space: TvSettingsTokens.spaceMd }) {
        Button(this.mateTvVoiceLearning ? '请按下并松开语音键' : '检测语音键', { type: ButtonType.Normal })
          .id('MateTvVoiceLearning').focusable(true)
          .fontSize(TvSettingsTokens.fontControl).fontColor(TvSettingsTokens.textPrimary)
          .height(TvSettingsTokens.controlHeight).borderRadius(TvSettingsTokens.controlRadius)
          .padding({ left: TvSettingsTokens.spaceLg, right: TvSettingsTokens.spaceLg })
          .backgroundColor(TvSettingsTokens.controlBackground)
          .onClick((): void => { this.mateTvStartVoiceLearning(); })
          .onKeyEvent((event: KeyEvent): boolean => this.mateTvLearnVoiceKey(event))
        Text(this.mateTvVoiceStatus)
          .fontSize(TvSettingsTokens.fontCaption).fontColor(TvSettingsTokens.textSecondary)
          .layoutWeight(1).maxLines(2)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private mateTvRemoteActionSettings() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Row({ space: TvSettingsTokens.spaceMd }) {
        Select(['↑ 上', '↓ 下', '← 左', '→ 右', '菜单键', '语音键'].map((label: string): SelectOption => ({ value: label })))
          .selected(this.mateTvRemoteSelectedKey)
          .value(['↑ 上', '↓ 下', '← 左', '→ 右', '菜单键', '语音键'][this.mateTvRemoteSelectedKey])
          .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
          .height(TvSettingsTokens.controlHeight).backgroundColor(TvSettingsTokens.controlBackground)
          .layoutWeight(1).accessibilityText('遥控器按键')
          .onSelect((index: number): void => { this.mateTvSelectRemoteKey(index); })
        this.mateTvRemoteSettingsButton('恢复本键默认', (): void => { this.mateTvResetRemoteKey(); })
      }.width('100%')
      if (this.mateTvRemoteSelectedKey === 5) {
        this.mateTvRemoteVoiceSettings()
      }
      ForEach(['单击', '双击', '长按'], (label: string, gesture: number): void => {
        Row({ space: TvSettingsTokens.spaceLg }) {
          Text(label).fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textPrimary).layoutWeight(1)
          Select(this.mateTvRemoteGestureOptions(gesture).map((item: TvRemoteActionChoice): SelectOption => ({ value: item.label })))
            .selected(this.mateTvRemoteGestureOptions(gesture).findIndex((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteGestureValue(gesture)))
            .value(this.mateTvRemoteGestureOptions(gesture).find((item: TvRemoteActionChoice): boolean => item.id === this.mateTvRemoteGestureValue(gesture))?.label ?? '原按键')
            .enabled(this.mateTvRemoteSelectedKey !== 5 || this.mateTvRemoteKeys.voiceKeyCode >= 0)
            .font({ size: TvSettingsTokens.fontControl }).fontColor(TvSettingsTokens.textPrimary)
            .height(TvSettingsTokens.controlHeight).backgroundColor(TvSettingsTokens.controlBackground)
            .layoutWeight(3).accessibilityText(label + '动作')
            .onSelect((selected: number): void => { this.mateTvChooseRemoteAction(gesture, selected); })
        }.width('100%')
      }, (label: string): string => label)
      Text('双击间隔 0.28 秒 · 长按 0.65 秒')
        .fontSize(TvSettingsTokens.fontCaption).fontColor(TvSettingsTokens.textSecondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private mateTvRemoteKeySettings() {
    Column({ space: TvSettingsTokens.spaceXl }) {
      TvSettingsSection({ title: '遥控器设备', description: '配置仅用于当前电脑',
        content: (): void => { this.mateTvRemoteDeviceSettings(); } })
      TvSettingsSection({ title: '按键与动作',
        content: (): void => { this.mateTvRemoteActionSettings(); } })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
