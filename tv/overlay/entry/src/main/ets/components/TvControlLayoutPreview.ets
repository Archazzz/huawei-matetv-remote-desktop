import { TvSettingsTokens } from '../theme/TvSettingsTokens';
import { TvControlLayoutPreviewTokens as Preview } from '../theme/TvControlLayoutPreviewTokens';
import { TvControlLayoutPreviewGeometry, tvControlLayoutPreviewGeometry } from '../services/TvControlLayoutPreviewGeometry';

/** Text-only miniature. Selection and persistence belong to the settings page. */
@Component
export struct TvControlLayoutPreview {
  @Prop corner: number = 2;
  @Prop horizontal: boolean = false;
  @Prop labels: string[] = [];
  @Prop joystick: boolean = false;

  private geometry(): TvControlLayoutPreviewGeometry {
    return tvControlLayoutPreviewGeometry(this.corner, this.horizontal, this.labels.length);
  }

  private allLabels(): string[] {
    return this.joystick ? [...this.labels, '摇杆'] : this.labels;
  }

  @Builder
  private items() {
    ForEach(this.labels, (label: string): void => {
      Text(label).fontSize(Preview.itemFont).fontColor(TvSettingsTokens.textPrimary)
        .textAlign(TextAlign.Center).width(Preview.itemWidth).height(Preview.itemHeight)
        .backgroundColor(Preview.itemBackground).borderRadius(Preview.itemRadius)
    }, (label: string): string => label)
  }

  build() {
    Column({ space: TvSettingsTokens.spaceMd }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Rect().width(Preview.width).height(Preview.height).radius(Preview.canvasRadius)
          .fill(Preview.canvasBackground).stroke(Preview.canvasBorder).strokeWidth(Preview.borderWidth)
        if (this.horizontal) {
          Row({ space: Preview.gap }) { this.items() }
            .position({ x: this.geometry().x, y: this.geometry().y })
        } else {
          Column({ space: Preview.gap }) { this.items() }
            .position({ x: this.geometry().x, y: this.geometry().y })
        }
        if (this.joystick) {
          Text('摇杆').fontSize(Preview.joystickFont).fontColor(TvSettingsTokens.textPrimary)
            .textAlign(TextAlign.Center).width(Preview.joystickSize).height(Preview.joystickSize)
            .backgroundColor(Preview.joystickBackground).borderRadius(Preview.joystickSize / 2)
            .position({ x: this.geometry().joystickX, y: this.geometry().joystickY })
        }
      }.width(Preview.width).height(Preview.height)
      Text('当前 ' + this.allLabels().length.toString() + ' 个控件 · ' + this.allLabels().join(' → '))
        .fontSize(TvSettingsTokens.fontCaption).fontColor(TvSettingsTokens.textSecondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).hitTestBehavior(HitTestMode.None)
  }
}
