export interface TvRemoteActionChoice { id: string; label: string; }
export const TV_REMOTE_KEY_ACTIONS: TvRemoteActionChoice[] = [
  { id: 'original', label: '原按键' },
  { id: 'arrow-up', label: '电脑 ↑' }, { id: 'arrow-down', label: '电脑 ↓' },
  { id: 'arrow-left', label: '电脑 ←' }, { id: 'arrow-right', label: '电脑 →' },
  { id: 'enter', label: 'Enter 确认' }, { id: 'escape', label: 'Esc 取消' },
  { id: 'space', label: '空格 / 播放暂停' }, { id: 'tab', label: 'Tab 下一项' },
  { id: 'page-up', label: 'Page Up 上一页' }, { id: 'page-down', label: 'Page Down 下一页' },
  { id: 'copy', label: '复制' }, { id: 'paste', label: '粘贴' },
  { id: 'select-all', label: '全选' }, { id: 'undo', label: '撤销' },
  { id: 'scroll-up', label: '滚轮向上' }, { id: 'scroll-down', label: '滚轮向下' },
  { id: 'pan-up', label: '画面向上移动' }, { id: 'pan-down', label: '画面向下移动' },
  { id: 'pan-left', label: '画面向左移动' }, { id: 'pan-right', label: '画面向右移动' },
  { id: 'next-display', label: '下一块显示器' },
  { id: 'open-settings', label: '打开设置' }, { id: 'open-dictation', label: '文字与听写' },
  { id: 'toggle-fit', label: '完整画面 / 短边铺满' }, { id: 'none', label: '不执行操作' }
];

export interface TvRemoteKeyProfile {
  version: number;
  enabled: boolean;
  fingerprint: string;
  deviceName: string;
  actions: string[];
  doubleActions: string[];
  longActions: string[];
  voiceKeyCode: number;
}
export interface TvRemoteDevice {
  id: number;
  name: string;
  vendor: number;
  product: number;
  uniq: string;
  virtual: boolean;
}
export function defaultTvRemoteKeyProfile(): TvRemoteKeyProfile {
  return { version: 2, enabled: true, fingerprint: '', deviceName: '',
    actions: ['original', 'original', 'original', 'original', 'original', 'original'],
    doubleActions: ['disabled', 'disabled', 'disabled', 'disabled', 'disabled', 'disabled'],
    longActions: ['disabled', 'disabled', 'disabled', 'disabled', 'disabled', 'disabled'], voiceKeyCode: -1 };
}
export function tvRemoteActionValid(action: string): boolean {
  return TV_REMOTE_KEY_ACTIONS.some((item: TvRemoteActionChoice): boolean => item.id === action);
}
export function tvRemoteVoiceCandidate(keyCode: number): boolean {
  // System Home/Back/Power/Volume and arbitrary keyboard keys are never learnable.
  // These are candidates only: the UI must observe a full physical Down/Up pair.
  return keyCode === 2722 || keyCode === 9;
}
export function tvRemoteGestureActionValid(action: string): boolean {
  return action === 'disabled' || (action !== 'original' && tvRemoteActionValid(action));
}
export function parseTvRemoteKeyProfile(raw: string): TvRemoteKeyProfile {
  try {
    const value = JSON.parse(raw) as TvRemoteKeyProfile;
    if (value === null || (value.version !== 1 && value.version !== 2) || typeof value.enabled !== 'boolean' ||
        typeof value.fingerprint !== 'string' || value.fingerprint.length > 1024 ||
        typeof value.deviceName !== 'string' || value.deviceName.length > 256 ||
        !Array.isArray(value.actions) || value.actions.length !== (value.version === 1 ? 4 : 6) ||
        !value.actions.every((action: string): boolean => typeof action === 'string' && tvRemoteActionValid(action))) {
      return defaultTvRemoteKeyProfile();
    }
    const result: TvRemoteKeyProfile = defaultTvRemoteKeyProfile();
    result.enabled = value.enabled; result.fingerprint = value.fingerprint; result.deviceName = value.deviceName;
    for (let index: number = 0; index < value.actions.length; index++) { result.actions[index] = value.actions[index]; }
    if (value.version === 1) { return result; }
    if (!Array.isArray(value.doubleActions) || value.doubleActions.length !== 6 ||
        !value.doubleActions.every((action: string): boolean => typeof action === 'string' && tvRemoteGestureActionValid(action)) ||
        !Array.isArray(value.longActions) || value.longActions.length !== 6 ||
        !value.longActions.every((action: string): boolean => typeof action === 'string' && tvRemoteGestureActionValid(action)) ||
        (value.voiceKeyCode !== -1 && !tvRemoteVoiceCandidate(value.voiceKeyCode))) { return defaultTvRemoteKeyProfile(); }
    result.doubleActions = value.doubleActions.slice(); result.longActions = value.longActions.slice();
    result.voiceKeyCode = value.voiceKeyCode;
    // An application cannot replay the system assistant after waiting for a gesture.
    if (result.actions[5] === 'original' && (result.doubleActions[5] !== 'disabled' || result.longActions[5] !== 'disabled')) {
      result.actions[5] = 'none';
    }
    return result;
  } catch (_error) { return defaultTvRemoteKeyProfile(); }
}
// Numeric device IDs can be reused. Only a unique hardware identity can restore a
// saved binding; name/vendor/product alone must never automatically select a keyboard.
export function tvRemoteDeviceFingerprint(device: TvRemoteDevice): string {
  const uniq: string = device.uniq.trim();
  if (device.virtual || !Number.isInteger(device.id) || device.id < 0 ||
      !Number.isInteger(device.vendor) || !Number.isInteger(device.product) ||
      device.name.length > 256 || uniq.length < 4 ||
      uniq.length > 512 || ['unknown', 'null', '0000', 'none'].indexOf(uniq.toLowerCase()) >= 0) { return ''; }
  return JSON.stringify([device.name, device.vendor.toString(), device.product.toString(), uniq]);
}
export function resolveTvRemoteDevice(fingerprint: string, devices: TvRemoteDevice[]): number {
  if (fingerprint.length === 0) { return -1; }
  const matches: TvRemoteDevice[] = devices.filter((device: TvRemoteDevice): boolean =>
    !device.virtual && tvRemoteDeviceFingerprint(device) === fingerprint);
  return matches.length === 1 ? matches[0].id : -1;
}
export function tvRemoteDirectionIndex(keyCode: number): number {
  return Number.isInteger(keyCode) && keyCode >= 2012 && keyCode <= 2015 ? keyCode - 2012 : -1;
}
export function tvRemoteActionKeys(action: string, mac: boolean): number[] {
  const modifier: number = mac ? 2076 : 2072;
  switch (action) {
    case 'arrow-up': return [2012]; case 'arrow-down': return [2013];
    case 'arrow-left': return [2014]; case 'arrow-right': return [2015];
    case 'enter': return [2054]; case 'escape': return [2070];
    case 'space': return [2050]; case 'tab': return [2049];
    case 'page-up': return [2068]; case 'page-down': return [2069];
    case 'copy': return [modifier, 2019]; case 'paste': return [modifier, 2038];
    case 'select-all': return [modifier, 2017]; case 'undo': return [modifier, 2042];
    default: return [];
  }
}
export function tvRemoteActionRepeats(action: string): boolean {
  return action.indexOf('arrow-') === 0 || action.indexOf('scroll-') === 0 ||
    action.indexOf('pan-') === 0 || action === 'page-up' || action === 'page-down';
}
export interface TvRemoteKeyDecision { consume: boolean; action: string; }
interface TvRemoteHeldKey {
  keyCode: number; deviceId: number; index: number;
  single: string; double: string; long: string;
  down: boolean; downAt: number; releasedAt: number; second: boolean;
  longFired: boolean; cancelled: boolean; last: number;
}
export function tvRemoteKeyIndex(keyCode: number, profile: TvRemoteKeyProfile): number {
  const direction: number = tvRemoteDirectionIndex(keyCode);
  if (direction >= 0) { return direction; }
  if (keyCode === 2067) { return 4; }
  if (tvRemoteVoiceCandidate(keyCode) && profile.voiceKeyCode === keyCode) { return 5; }
  return -1;
}
export class TvRemoteKeyPolicy {
  private held: Map<string, TvRemoteHeldKey> = new Map<string, TvRemoteHeldKey>();
  private pending: string[] = [];

  cancel(): void {
    this.pending = [];
    this.held.forEach((value: TvRemoteHeldKey, key: string): void => {
      if (value.down) { value.cancelled = true; }
      else { this.held.delete(key); }
    });
  }
  drain(): string[] { const actions: string[] = this.pending; this.pending = []; return actions; }
  hasPending(): boolean {
    let result: boolean = false;
    this.held.forEach((value: TvRemoteHeldKey): void => {
      if (!value.cancelled && ((!value.down && value.releasedAt >= 0) ||
          (value.down && value.long !== 'disabled' && !value.longFired))) { result = true; }
    });
    return result;
  }
  private singleAction(value: TvRemoteHeldKey): string {
    if (value.single === 'original') { return value.index === 5 ? '' : 'original:' + value.keyCode.toString(); }
    return value.single === 'none' ? '' : value.single;
  }
  private current(value: TvRemoteHeldKey, bound: number, profile: TvRemoteKeyProfile): boolean {
    return profile.enabled && value.deviceId === bound && tvRemoteKeyIndex(value.keyCode, profile) === value.index &&
      value.single === profile.actions[value.index] && value.double === profile.doubleActions[value.index] &&
      value.long === profile.longActions[value.index];
  }
  advance(now: number, active: boolean, bound: number, profile: TvRemoteKeyProfile): void {
    if (!active) { this.cancel(); return; }
    this.held.forEach((value: TvRemoteHeldKey, key: string): void => {
      if (!this.current(value, bound, profile)) { value.cancelled = true; }
      if (value.cancelled) { if (!value.down) { this.held.delete(key); } return; }
      if (value.down && value.long !== 'disabled' && !value.longFired && now - value.downAt >= 650) {
        value.longFired = true; value.releasedAt = -1;
        if (value.long !== 'none') { this.pending.push(value.long); }
      } else if (!value.down && value.releasedAt >= 0 && now - value.releasedAt >= 280) {
        const action: string = this.singleAction(value);
        if (action.length > 0) { this.pending.push(action); }
        this.held.delete(key);
      }
    });
  }
  route(keyCode: number, deviceId: number, down: boolean, active: boolean,
    boundDeviceId: number, profile: TvRemoteKeyProfile, now: number): TvRemoteKeyDecision {
    this.advance(now, active, boundDeviceId, profile);
    if (!Number.isInteger(deviceId) || deviceId < 0) { return { consume: false, action: '' }; }
    const identity: string = deviceId.toString() + ':' + keyCode.toString();
    const existing: TvRemoteHeldKey | undefined = this.held.get(identity);
    const index: number = tvRemoteKeyIndex(keyCode, profile);
    if (index < 0 && existing === undefined) { return { consume: false, action: '' }; }
    if (existing !== undefined && existing.cancelled) {
      if (!down) { this.held.delete(identity); }
      return { consume: active, action: '' };
    }
    if (existing !== undefined) {
      const advanced: boolean = existing.double !== 'disabled' || existing.long !== 'disabled';
      if (down) {
        if (!existing.down) {
          existing.down = true; existing.downAt = now; existing.second = true; existing.releasedAt = -1;
        } else if (!advanced && tvRemoteActionRepeats(existing.single) && now - existing.last >= 80) {
          existing.last = now; return { consume: true, action: this.singleAction(existing) };
        }
        return { consume: true, action: '' };
      }
      if (!existing.down) { return { consume: true, action: '' }; }
      existing.down = false;
      if (!advanced || existing.longFired) { this.held.delete(identity); return { consume: true, action: '' }; }
      if (existing.second && existing.double !== 'disabled') {
        this.held.delete(identity);
        return { consume: true, action: existing.double === 'none' ? '' : existing.double };
      }
      if (existing.double === 'disabled') {
        this.held.delete(identity); return { consume: true, action: this.singleAction(existing) };
      }
      existing.releasedAt = now;
      return { consume: true, action: '' };
    }
    if (!down || !profile.enabled || boundDeviceId < 0 || deviceId !== boundDeviceId || index < 0) {
      return { consume: false, action: '' };
    }
    const single: string = profile.actions[index];
    const double: string = profile.doubleActions[index];
    const long: string = profile.longActions[index];
    const advanced: boolean = double !== 'disabled' || long !== 'disabled';
    if (single === 'original' && !advanced) { return { consume: false, action: '' }; }
    if (this.held.size >= 32) { return { consume: active, action: '' }; }
    const value: TvRemoteHeldKey = { keyCode: keyCode, deviceId: deviceId, index: index,
      single: single, double: double, long: long, down: true, downAt: now, releasedAt: -1,
      second: false, longFired: false, cancelled: !active, last: now };
    this.held.set(identity, value);
    return { consume: active, action: active && !advanced ? this.singleAction(value) : '' };
  }
}
