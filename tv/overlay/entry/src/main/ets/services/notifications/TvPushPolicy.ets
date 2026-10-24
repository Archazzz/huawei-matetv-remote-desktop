export const TV_PUSH_NONCE: string = 'screenLinkPushNonce';
export const TV_PUSH_INSTALLATION: string = 'screenLinkInstallationId';

export function validPushInstallation(value: string): boolean {
  return /^[a-f0-9-]{36}$/.test(value);
}

export function validPushClick(nonce: string, installation: string, expected: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/.test(nonce) && validPushInstallation(installation) && installation === expected;
}

export function pushErrorText(code: number): string {
  if (code === 1000900010) { return '应用推送身份未通过，请检查自有项目签名（1000900010）'; }
  if (code === 1000900012) { return 'Push Kit 尚未开通或签名尚未更新（1000900012）'; }
  if (code === 1000900014) { return '当前设备不支持获取推送标识（1000900014）'; }
  if (code === 1000900013) { return '推送服务地区不匹配（1000900013）'; }
  if (code === 409) { return '中转已绑定另一台电视，请先解除原绑定（409）'; }
  return '后台推送暂不可用（' + (Number.isFinite(code) ? code : -1).toString() + '）';
}
