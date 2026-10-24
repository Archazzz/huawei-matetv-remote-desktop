/** Explicit frame-rate limits are independent of TV resolution and bitrate. */
export const RUSTDESK_FPS_PREF_KEY: string = 'rustdeskFps';
export const RUSTDESK_FPS_AUTO: number = 0;
export const RUSTDESK_BEST_QUALITY_FPS: number = 30;
export const RUSTDESK_FPS_CHOICES: number[] = [RUSTDESK_FPS_AUTO, 30, 60, 120];

export function normalizeRustDeskFps(value: number): number {
  return value === 30 || value === 60 || value === 120 ? value : RUSTDESK_FPS_AUTO;
}

export function rustDeskFpsLockedByQuality(_quality: number): boolean { return false; }

export function rustDeskFpsChoiceLabel(fps: number): string {
  const normalized: number = normalizeRustDeskFps(fps);
  return normalized === RUSTDESK_FPS_AUTO ? '自动' : normalized.toString() + ' 帧';
}

export function rustDeskFpsSummary(quality: number, fps: number): string {
  const normalized: number = normalizeRustDeskFps(fps);
  return normalized > 0 ? normalized.toString() + ' 帧上限' :
    (quality === 0 || quality === 2 ? '自动 · 30 帧' : '自动 · 随画质档');
}
