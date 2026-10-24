  @Builder
  private mateTvControlLayoutOptions() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Row({ space: TvSettingsTokens.spaceMd }) {
        Text('位置').fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textSecondary)
        Select([{ value: '左上' }, { value: '右上' }, { value: '左下' }, { value: '右下' }])
          .selected(this.mateTvControlsCorner).value(['左上', '右上', '左下', '右下'][this.mateTvControlsCorner])
          .font({ size: TvSettingsTokens.fontControl }).height(TvSettingsTokens.controlHeight).layoutWeight(1)
          .onSelect((index: number): void => {
            if (index >= 0 && index < 4) { this.mateTvSaveControls(index, this.mateTvControlsHorizontal); }
          })
      }.width('100%')
      Row({ space: TvSettingsTokens.spaceMd }) {
        Text('排列').fontSize(TvSettingsTokens.fontBody).fontColor(TvSettingsTokens.textSecondary)
        Select([{ value: '横向' }, { value: '纵向' }])
          .selected(this.mateTvControlsHorizontal ? 0 : 1).value(this.mateTvControlsHorizontal ? '横向' : '纵向')
          .font({ size: TvSettingsTokens.fontControl }).height(TvSettingsTokens.controlHeight).layoutWeight(1)
          .onSelect((index: number): void => {
            if (index === 0 || index === 1) { this.mateTvSaveControls(this.mateTvControlsCorner, index === 0); }
          })
      }.width('100%')
      TvControlLayoutPreview({ corner: this.mateTvControlsCorner, horizontal: this.mateTvControlsHorizontal,
        labels: this.mateTvSmallLabels(), joystick: this.mateTvViewCanX || this.mateTvViewCanY })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
