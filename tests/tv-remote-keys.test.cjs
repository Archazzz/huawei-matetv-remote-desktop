// Execute the shipped ArkTS policy, including held-key and device identity boundaries.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const source = readFileSync('tv/overlay/entry/src/main/ets/services/TvRemoteKeyPolicy.ets', 'utf8').replace(/^export /gm, '');
const api = vm.createContext({});
vm.runInContext(stripTypeScriptTypes(source + '\nglobalThis.api = { TvRemoteKeyPolicy, defaultTvRemoteKeyProfile, parseTvRemoteKeyProfile, tvRemoteDeviceFingerprint, resolveTvRemoteDevice, tvRemoteActionKeys };'), api);
const { TvRemoteKeyPolicy, defaultTvRemoteKeyProfile, parseTvRemoteKeyProfile, tvRemoteDeviceFingerprint, resolveTvRemoteDevice, tvRemoteActionKeys } = api.api;
const plain = value => JSON.parse(JSON.stringify(value));
function setup(action = 'arrow-up') {
  const profile = defaultTvRemoteKeyProfile(); profile.actions[0] = action;
  const policy = new TvRemoteKeyPolicy();
  return { policy, profile, route: (down = true, time = 1000, active = true, device = 17, bound = 17) =>
    plain(policy.route(2012, device, down, active, bound, profile, time)) };
}
const none = { consume: false, action: '' };

test('unbound/default and a separate Bluetooth keyboard preserve upstream direction handling', () => {
  const { route } = setup();
  assert.deepEqual(route(true, 1000, true, 21), none);
  assert.deepEqual(route(true, 1000, true, 17, -1), none);
  const original = setup('original');
  assert.deepEqual(original.route(), none);
  assert.deepEqual(original.route(false), none);
});

test('each mapped tap has one decision on Down and none on Up; unknown release passes through', () => {
  const { route } = setup('enter');
  assert.deepEqual(route(), { consume: true, action: 'enter' });
  assert.deepEqual(route(false), { consume: true, action: '' });
  assert.deepEqual(route(false), none);
  assert.deepEqual(route(), { consume: true, action: 'enter' });
});

test('arrows repeat at most every 80ms; shortcuts and display switching execute once per hold', () => {
  const { route } = setup();
  assert.equal(route().action, 'arrow-up');
  assert.equal(route(true, 1079).action, '');
  assert.equal(route(true, 1080).action, 'arrow-up');
  for (const action of ['copy', 'paste', 'select-all', 'undo', 'enter', 'next-display', 'none']) {
    const s = setup(action);
    assert.equal(s.route().action, action === 'none' ? '' : action);
    assert.equal(s.route(true, 2000).action, '');
    s.route(false, 2100);
    assert.equal(s.route(true, 2200).action, action === 'none' ? '' : action);
  }
});

test('panel/background/focus cancellation drains Up and cannot revive with OS repeat', () => {
  const { policy, route } = setup('scroll-up');
  route(); policy.cancel();
  assert.equal(route(true, 1300).action, '');
  assert.deepEqual(route(false, 1400, false), none);
  assert.equal(route(true, 1500).action, 'scroll-up');
  assert.deepEqual(route(true, 1600, false), none);
  assert.equal(route(true, 1700).action, '');
  route(false, 1800);
  assert.equal(route(true, 1900).action, 'scroll-up');
});

test('a direction first pressed in a local panel remains local until release', () => {
  const { route } = setup('pan-left');
  assert.deepEqual(route(true, 1000, false), none);
  assert.equal(route(true, 1200, true).action, '');
  route(false, 1300);
  assert.equal(route(true, 1400).action, 'pan-left');
});

test('binding change, disabled profile, and action change cancel an existing hold', () => {
  for (const mutation of ['binding', 'disabled', 'action']) {
    const { profile, route } = setup(); route();
    if (mutation === 'disabled') profile.enabled = false;
    if (mutation === 'action') profile.actions[0] = 'arrow-down';
    assert.equal(route(true, 1200, true, 17, mutation === 'binding' ? 18 : 17).action, '');
    profile.enabled = true; profile.actions[0] = 'arrow-up';
    assert.equal(route(true, 1400).action, '');
    route(false, 1500);
    assert.equal(route(true, 1600).action, 'arrow-up');
  }
});

test('durable binding requires unique nonvirtual hardware identity; IDs may change', () => {
  const device = { id: 17, name: 'TV remote', vendor: 1, product: 2, uniq: 'stable-serial', virtual: false };
  const fingerprint = tvRemoteDeviceFingerprint(device);
  assert.ok(fingerprint);
  assert.equal(resolveTvRemoteDevice(fingerprint, [{ ...device, id: 22 }]), 22);
  assert.equal(resolveTvRemoteDevice(fingerprint, [device, { ...device, id: 22 }]), -1);
  assert.equal(resolveTvRemoteDevice(fingerprint, [{ ...device, uniq: 'another-serial' }]), -1);
  for (const fields of [{ uniq: '' }, { uniq: 'unknown' }, { virtual: true }, { vendor: NaN }, { id: -1 }]) {
    assert.equal(tvRemoteDeviceFingerprint({ ...device, ...fields }), '');
  }
});

test('malformed per-host preferences fail closed without mapping arbitrary actions', () => {
  const profile = defaultTvRemoteKeyProfile();
  for (const raw of ['null', 'bad', '{}', JSON.stringify({ ...profile, actions: ['exec', 'original', 'original', 'original'] }),
    JSON.stringify({ ...profile, enabled: 'true' }), JSON.stringify({ ...profile, version: 2 })]) {
    assert.deepEqual(plain(parseTvRemoteKeyProfile(raw)), plain(profile));
  }
  const custom = { ...profile, actions: ['copy', 'paste', 'page-up', 'scroll-down'] };
  assert.deepEqual(plain(parseTvRemoteKeyProfile(JSON.stringify(custom))), plain(custom));
});

test('shortcut modifiers are selected from the remote computer platform', () => {
  assert.deepEqual(plain(tvRemoteActionKeys('copy', true)), [2076, 2019]);
  assert.deepEqual(plain(tvRemoteActionKeys('copy', false)), [2072, 2019]);
  assert.deepEqual(plain(tvRemoteActionKeys('paste', true)), [2076, 2038]);
  assert.deepEqual(plain(tvRemoteActionKeys('undo', false)), [2072, 2042]);
});

// Run the actual integration methods with a UI/device boundary; no generated project edits.
const fragment = readFileSync('tv/fragments/remote-key-members.ets', 'utf8').split('  @Builder')[0].replace(/@State /g, '');
vm.runInContext(stripTypeScriptTypes('class RemoteKeyHarness {\n' + fragment + '\n}\nglobalThis.RemoteKeyHarness = RemoteKeyHarness;'), api);
vm.runInContext(stripTypeScriptTypes(readFileSync('.work/client/entry/src/main/ets/services/RemoteSessionInputOwner.ets', 'utf8')
  .replace(/^export /gm, '') + '\nglobalThis.RemoteSessionInputOwner = RemoteSessionInputOwner;'), api);
api.KeyType = { Down: 0, Up: 1 };
api.RemoteKeyboardLayout = { MACOS: 'macos' };
api.promptAction = { showToast() {} };
api.setTimeout = () => 1; api.clearTimeout = () => {};
api.getContext = () => ({});
function harness() {
  const h = new api.RemoteKeyHarness();
  const calls = [];
  Object.assign(h, {
    mateTvMode: true, connected: true, sessionId: 3, inputForwardReady: true,
    mateTvLeaving: false, mateTvDisplayOpen: false, mateTvTextOpen: false,
    keyboardOpen: false, keyboardImeActive: false,
    remoteKeyboardModalOwnsInput: () => false, remoteKeyboardForeground: () => true,
    harmonyShortcutRemoteInputAllowed: () => true, sessionInputOwner: new api.RemoteSessionInputOwner(),
    canForwardInput: () => true, physicalKeyboardLayoutConfirmed: true,
    remoteKeyboardLayoutForSession: () => 'macos',
    sendVirtualKeyTap: (...args) => calls.push(['tap', ...args]),
    sendShortcutSequence: (...args) => calls.push(['shortcut', ...args]),
    mateTvNextDisplay: () => calls.push(['display']),
    mateTvRemoteDeviceId: 17,
  });
  h.mateTvRemoteKeys.actions[0] = 'copy';
  return { h, calls, event: down => ({ keyCode: 2012, deviceId: 17, type: down ? 0 : 1, stopPropagation() {} }) };
}

test('integration routes complete taps/chords and never emits an independent held modifier', () => {
  const { h, calls, event } = harness();
  assert.equal(h.mateTvRouteRemoteKey(event(true)), true);
  assert.equal(h.mateTvRouteRemoteKey(event(false)), true);
  assert.deepEqual(plain(calls), [['shortcut', [2076, 2019], 'copy']]);
  h.mateTvRemoteKeys.actions[0] = 'enter';
  h.mateTvRouteRemoteKey(event(true)); h.mateTvRouteRemoteKey(event(false));
  assert.deepEqual(calls[1], ['tap', 2054, 'enter']);
});

test('integration gates settings, dictation, IME, lifecycle, modal and session ownership', () => {
  for (const blocker of ['mateTvDisplayOpen', 'mateTvTextOpen', 'keyboardOpen', 'keyboardImeActive', 'mateTvLeaving',
    'remoteKeyboardModalOwnsInput', 'remoteKeyboardForeground', 'harmonyShortcutRemoteInputAllowed', 'sessionInputOwner']) {
    const { h, calls, event } = harness();
    if (blocker === 'sessionInputOwner') h.sessionInputOwner.acquire('test-menu');
    else if (typeof h[blocker] === 'function') h[blocker] = () => blocker === 'remoteKeyboardModalOwnsInput';
    else h[blocker] = true;
    assert.equal(h.mateTvRouteRemoteKey(event(true)), false, blocker);
    assert.equal(calls.length, 0, blocker);
  }
});

test('integration cannot send a shortcut before the remote platform layout is confirmed', () => {
  const { h, calls, event } = harness(); h.physicalKeyboardLayoutConfirmed = false;
  h.mateTvRouteRemoteKey(event(true)); h.mateTvRouteRemoteKey(event(false));
  assert.equal(calls.length, 0);
});

test('late device discovery cannot bind after the panel closes', async () => {
  let resolve;
  api.inputDevice = { getDeviceInfo: () => new Promise(done => { resolve = done; }) };
  const { h, event } = harness();
  h.mateTvDisplayOpen = true; h.mateTvRemoteCapturing = true;
  assert.equal(h.mateTvCaptureRemoteKey(event(true)), true);
  h.mateTvCancelRemoteCapture(); h.mateTvDisplayOpen = false;
  resolve({ id: 17, name: 'Remote', vendor: 1, product: 2, uniq: 'unique' });
  await Promise.resolve();
  assert.equal(h.mateTvRemoteCandidate, null);
  assert.equal(h.mateTvRemoteCandidateName, '');
});

test('no durable identity produces an explicit connection-only binding; settings persist per host', () => {
  const written = [];
  api.preferences = { getPreferencesSync: () => ({ putSync: (key, raw) => written.push([key, JSON.parse(raw)]), flushSync() {} }) };
  const { h } = harness();
  h.pendingHost = { userId: 'account', id: 'computer-a' };
  h.mateTvDisplayOpen = true;
  h.mateTvRemoteCandidate = { id: 17, name: 'Remote', vendor: 1, product: 2, uniq: '', virtual: false };
  h.mateTvConfirmRemoteBinding();
  assert.match(h.mateTvRemoteBindingStatus, /^仅本次连接/);
  assert.equal(written[0][1].fingerprint, '');
  assert.equal(h.mateTvRemoteDeviceId, 17);
  const firstKey = written[0][0];
  h.pendingHost.id = 'computer-b'; h.mateTvSaveRemoteKeys();
  assert.notEqual(written[1][0], firstKey);
});

// Mirror the two ownership boundaries in handleXComponentKey: the mapper gets
// first refusal; only an unconsumed event enters upstream allowsPhysical once.
function dispatchThroughOwners(h, code, device, down) {
  const intercepted = h.mateTvRouteRemoteKey({ keyCode: code, deviceId: device,
    type: down ? api.KeyType.Down : api.KeyType.Up, stopPropagation() {} });
  return { intercepted, upstreamAllowed: intercepted ? null : h.sessionInputOwner.allowsPhysical(code, down) };
}

test('real input owner receives both Down and Up for every untouched keyboard path', () => {
  for (const scenario of [
    { name: 'unbound ordinary letter', code: 2017, device: 88, bound: -1 },
    { name: 'unbound arrow', code: 2012, device: 88, bound: -1 },
    { name: 'other Bluetooth keyboard arrow', code: 2012, device: 88, bound: 17 },
    { name: 'bound remote default original', code: 2012, device: 17, bound: 17, original: true },
    { name: 'bound remote ordinary letter', code: 2017, device: 17, bound: 17 },
  ]) {
    const { h, calls } = harness();
    h.mateTvRemoteDeviceId = scenario.bound;
    if (scenario.original) h.mateTvRemoteKeys.actions[0] = 'original';
    for (const down of [true, true, false]) {
      assert.deepEqual(dispatchThroughOwners(h, scenario.code, scenario.device, down),
        { intercepted: false, upstreamAllowed: true }, scenario.name + (down ? ' Down' : ' Up'));
    }
    assert.deepEqual(dispatchThroughOwners(h, scenario.code, scenario.device, false),
      { intercepted: false, upstreamAllowed: false }, scenario.name + ' duplicate Up');
    assert.equal(calls.length, 0);
  }
});

test('mapped remote press/release cannot consume a simultaneous Bluetooth keyboard lease', () => {
  const { h, calls } = harness();
  assert.deepEqual(dispatchThroughOwners(h, 2012, 88, true), { intercepted: false, upstreamAllowed: true });
  assert.deepEqual(dispatchThroughOwners(h, 2012, 17, true), { intercepted: true, upstreamAllowed: null });
  assert.deepEqual(dispatchThroughOwners(h, 2012, 17, false), { intercepted: true, upstreamAllowed: null });
  assert.deepEqual(dispatchThroughOwners(h, 2012, 88, false), { intercepted: false, upstreamAllowed: true });
  assert.equal(calls.length, 1);
});

test('real overlay owner cancels mapped holds while allowing release and a fresh press after close', () => {
  const { h, calls } = harness();
  h.mateTvRemoteKeys.actions[0] = 'arrow-up';
  h.sessionInputOwner.observe(() => h.mateTvRemotePolicy.cancel());
  dispatchThroughOwners(h, 2012, 17, true);
  const overlay = h.sessionInputOwner.acquire('MateTvDisplay');
  assert.deepEqual(dispatchThroughOwners(h, 2012, 17, true), { intercepted: false, upstreamAllowed: false });
  h.sessionInputOwner.release(overlay);
  assert.deepEqual(dispatchThroughOwners(h, 2012, 17, true), { intercepted: true, upstreamAllowed: null });
  assert.equal(calls.length, 1);
  dispatchThroughOwners(h, 2012, 17, false);
  dispatchThroughOwners(h, 2012, 17, true);
  dispatchThroughOwners(h, 2012, 17, false);
  assert.equal(calls.length, 2);
});
