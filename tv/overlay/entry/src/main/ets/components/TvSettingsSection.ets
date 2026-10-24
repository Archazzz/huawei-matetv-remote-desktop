import { TvSettingsTokens } from '../theme/TvSettingsTokens';

/** Layout only: the page owns the native controls and their input handling. */
@Component
export struct TvSettingsSection {
  @Prop title: string = '';
  @Prop description: string = '';

  @Builder
  private emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Column({ space: TvSettingsTokens.spaceXs }) {
        Text(this.title)
          .fontSize(TvSettingsTokens.fontSection)
          .fontWeight(FontWeight.Medium)
          .fontColor(TvSettingsTokens.textPrimary)
          .width('100%')
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(TvSettingsTokens.fontCaption)
            .fontColor(TvSettingsTokens.textSecondary)
            .width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
      this.content()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
