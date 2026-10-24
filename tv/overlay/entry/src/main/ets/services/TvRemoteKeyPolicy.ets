export interface TvRemoteActionChoice { id: string; label: string; }
export const TV_REMOTE_KEY_ACTIONS: TvRemoteActionChoice[] = [
  { id: 'original', label: '原方向键' },
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
  { id: 'next-display', label: '下一块显示器' }, { id: 'none', label: '不执行操作' }
];

export interface TvRemoteKeyProfile {
  version: number;
  enabled: boolean;
  fingerprint: string;
  deviceName: string;
  actions: string[];
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
  return { version: 1, enabled: true, fingerprint: '', deviceName: '',
    actions: ['original', 'original', 'original', 'original'] };
}
export function tvRemoteActionValid(action: string): boolean {
  return TV_REMOTE_KEY_ACTIONS.some((item: TvRemoteActionChoice): boolean => item.id === action);
}
export function parseTvRemoteKeyProfile(raw: string): TvRemoteKeyProfile {
  try {
    const value = JSON.parse(raw) as TvRemoteKeyProfile;
    if (value === null || value.version !== 1 || typeof value.enabled !== 'boolean' ||
        typeof value.fingerprint !== 'string' || value.fingerprint.length > 1024 ||
        typeof value.deviceName !== 'string' || value.deviceName.length > 256 ||
        !Array.isArray(value.actions) || value.actions.length !== 4 ||
        !value.actions.every((action: string): boolean => typeof action === 'string' && tvRemoteActionValid(action))) {
      return defaultTvRemoteKeyProfile();
    }
    return { version: 1, enabled: value.enabled, fingerprint: value.fingerprint,
      deviceName: value.deviceName, actions: value.actions.slice() };
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
interface TvRemoteHeldDirection { action: string; cancelled: boolean; last: number; }

export class TvRemoteKeyPolicy {
  private held: Map<string, TvRemoteHeldDirection> = new Map<string, TvRemoteHeldDirection>();

  cancel(): void {
    this.held.forEach((value: TvRemoteHeldDirection): void => { value.cancelled = true; });
  }

  route(keyCode: number, deviceId: number, down: boolean, active: boolean,
    boundDeviceId: number, profile: TvRemoteKeyProfile, now: number): TvRemoteKeyDecision {
    const index: number = tvRemoteDirectionIndex(keyCode);
    if (index < 0 || !Number.isInteger(deviceId) || deviceId < 0) { return { consume: false, action: '' }; }
    const identity: string = deviceId.toString() + ':' + keyCode.toString();
    const held: TvRemoteHeldDirection | undefined = this.held.get(identity);
    if (!down) {
      this.held.delete(identity);
      return { consume: active && held !== undefined && held.action !== 'original', action: '' };
    }
    if (!active) {
      if (held !== undefined) { held.cancelled = true; }
      else if (profile.enabled && deviceId === boundDeviceId &&
          profile.actions[index] !== 'original' && this.held.size < 32) {
        this.held.set(identity, { action: profile.actions[index], cancelled: true, last: now });
      }
      return { consume: false, action: '' };
    }
    if (held !== undefined) {
      if (!profile.enabled || deviceId !== boundDeviceId || profile.actions[index] !== held.action) {
        held.cancelled = true;
      }
      if (held.cancelled) { return { consume: true, action: '' }; }
      if (held.action === 'original') { return { consume: false, action: '' }; }
      if (!tvRemoteActionRepeats(held.action) || now - held.last < 80) { return { consume: true, action: '' }; }
      held.last = now;
      return { consume: true, action: held.action };
    }
    if (!profile.enabled || boundDeviceId < 0 || deviceId !== boundDeviceId) { return { consume: false, action: '' }; }
    const action: string = tvRemoteActionValid(profile.actions[index]) ? profile.actions[index] : 'original';
    if (action === 'original') { return { consume: false, action: '' }; }
    // Never clear cancelled keys to make room: an OS repeat must not revive a
    // held action after a lifecycle fence. Releases drain these bounded records.
    if (this.held.size >= 32) { return { consume: true, action: '' }; }
    this.held.set(identity, { action: action, cancelled: false, last: now });
    return { consume: action !== 'original', action: action === 'original' || action === 'none' ? '' : action };
  }
}
