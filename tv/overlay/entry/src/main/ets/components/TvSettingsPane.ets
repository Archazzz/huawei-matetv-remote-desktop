import { TvSettingsTokens } from '../theme/TvSettingsTokens';

/** One independently scrollable tab; all focus and input behavior stays native. */
@Component
export struct TvSettingsPane {
  @Builder
  private emptyContent() {}
  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Scroll() {
      Column({ space: TvSettingsTokens.spaceXl }) {
        this.content()
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ top: TvSettingsTokens.spaceXl, bottom: TvSettingsTokens.spaceXl,
          right: TvSettingsTokens.spaceMd })
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}
