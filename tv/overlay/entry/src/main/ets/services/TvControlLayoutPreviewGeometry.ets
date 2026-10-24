import { TvControlLayoutPreviewTokens as Preview } from '../theme/TvControlLayoutPreviewTokens';

export interface TvControlLayoutPreviewGeometry {
  x: number;
  y: number;
  width: number;
  height: number;
  joystickX: number;
  joystickY: number;
}

/** Pure miniature layout; never reads or mutates the remote canvas geometry. */
export function tvControlLayoutPreviewGeometry(corner: number, horizontal: boolean,
  count: number): TvControlLayoutPreviewGeometry {
  const right: boolean = corner % 2 === 1;
  const top: boolean = corner < 2;
  const width: number = horizontal ? count * (Preview.itemWidth + Preview.gap) - Preview.gap : Preview.itemWidth;
  const height: number = horizontal ? Preview.itemHeight : count * (Preview.itemHeight + Preview.gap) - Preview.gap;
  const x: number = right ? Preview.width - Preview.inset - width : Preview.inset;
  const y: number = top ? Preview.inset : Preview.height - Preview.inset - height;
  const joystickX: number = horizontal ?
    (right ? Preview.width - Preview.inset - Preview.joystickSize : Preview.inset) :
    (right ? x - Preview.joystickSize - Preview.gap : x + Preview.itemWidth + Preview.gap);
  const joystickY: number = !horizontal ?
    (top ? Preview.inset : Preview.height - Preview.inset - Preview.joystickSize) :
    (top ? y + Preview.itemHeight + Preview.gap : y - Preview.joystickSize - Preview.gap);
  return { x: x, y: y, width: width, height: height, joystickX: joystickX, joystickY: joystickY };
}
