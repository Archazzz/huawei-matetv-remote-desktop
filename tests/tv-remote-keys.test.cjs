// Execute the shipped ArkTS policy, including held-key and device identity boundaries.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const source = readFileSync('tv/overlay/entry/src/main/ets/services/TvRemoteKeyPolicy.ets', 'utf8').replace(/^export /gm, '');
const api = vm.createContext({});
vm.runInContext(stripTypeScriptTypes(source + '\nglobalThis.api = { TvRemoteKeyPolicy, defaultTvRemoteKeyProfile, parseTvRemoteKeyProfile, tvRemoteDeviceFingerprint, resolveTvRemoteDevice, tvRemoteActionKeys, tvRemoteVoiceCandidate };'), api);
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
    JSON.stringify({ ...profile, enabled: 'true' }), JSON.stringify({ ...profile, version: 3 })]) {
    assert.deepEqual(plain(parseTvRemoteKeyProfile(raw)), plain(profile));
  }
  const custom = { ...profile, actions: ['copy', 'paste', 'page-up', 'scroll-down', 'original', 'original'] };
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
api.hilog = { info() {} }; api.RD_DOMAIN = 0; api.RD_TAG = 'test';
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
    remoteKeyboardModalOwnsInput: () => false, remoteKeyboardModalFlags: () => [], remoteKeyboardForeground: () => true,
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

function gestures(single = 'enter', double = 'copy', long = 'paste', code = 2012) {
  const profile = defaultTvRemoteKeyProfile();
  const index = code === 2067 ? 4 : 0;
  profile.actions[index] = single; profile.doubleActions[index] = double; profile.longActions[index] = long;
  const policy = new TvRemoteKeyPolicy();
  return { policy, profile,
    route: (down, now, active = true, bound = 17) => plain(policy.route(code, 17, down, active, bound, profile, now)),
    advance: (now, active = true, bound = 17) => { policy.advance(now, active, bound, profile); return plain(policy.drain()); },
    drain: () => plain(policy.drain()),
  };
}

test('v1 per-computer mapping migrates without enabling gestures or claiming voice support', () => {
  const profile = parseTvRemoteKeyProfile(JSON.stringify({ version: 1, enabled: true, fingerprint: 'saved', deviceName: 'remote',
    actions: ['copy', 'paste', 'pan-left', 'pan-right'] }));
  assert.equal(profile.version, 2);
  assert.deepEqual(plain(profile.actions), ['copy', 'paste', 'pan-left', 'pan-right', 'original', 'original']);
  assert.equal(profile.voiceKeyCode, -1);
  assert.ok(profile.doubleActions.every(action => action === 'disabled'));
  assert.ok(profile.longActions.every(action => action === 'disabled'));
});

test('menu defaults pass through immediately and an explicit single-only mapping has no timer delay', () => {
  const p = new TvRemoteKeyPolicy(), profile = defaultTvRemoteKeyProfile();
  for (const down of [true, false]) assert.deepEqual(plain(p.route(2067, 17, down, true, 17, profile, 1000)), none);
  const s = gestures('enter', 'disabled', 'disabled', 2067);
  assert.equal(s.route(true, 1000).action, 'enter');
  assert.equal(s.policy.hasPending(), false);
  assert.equal(s.route(false, 1030).action, '');
});

test('single waits only for configured double window; double suppresses both singles', () => {
  const single = gestures('enter', 'copy', 'disabled');
  assert.equal(single.route(true, 0).action, ''); single.route(false, 30);
  assert.deepEqual(single.advance(309), []);
  assert.deepEqual(single.advance(310), ['enter']);
  assert.equal(single.policy.hasPending(), false);
  const double = gestures('enter', 'copy', 'disabled');
  double.route(true, 0); double.route(false, 30); double.route(true, 200);
  assert.equal(double.route(false, 230).action, 'copy');
  assert.deepEqual(double.advance(1000), []);
});

test('double boundary expiry emits the first single and starts a fresh click', () => {
  const s = gestures('enter', 'copy', 'disabled');
  s.route(true, 0); s.route(false, 20);
  assert.equal(s.route(true, 300).action, '');
  assert.deepEqual(s.drain(), ['enter']);
  assert.equal(s.route(false, 320).action, '');
  assert.deepEqual(s.advance(600), ['enter']);
});

test('long emits once at 650ms, ignores OS repeats and never emits single or double on release', () => {
  const s = gestures();
  s.route(true, 0); s.route(true, 200); s.route(true, 400);
  assert.deepEqual(s.advance(649), []);
  assert.deepEqual(s.advance(650), ['paste']);
  assert.equal(s.route(true, 900).action, '');
  assert.equal(s.route(false, 1000).action, '');
  assert.deepEqual(s.advance(1600), []);
});

test('long-only short press fires single on release, with no double wait', () => {
  const s = gestures('enter', 'disabled', 'paste');
  assert.equal(s.route(true, 0).action, '');
  assert.equal(s.route(false, 300).action, 'enter');
  assert.deepEqual(s.advance(1000), []);
});

test('holding the second click into a long press resolves to long only', () => {
  const s = gestures();
  s.route(true, 0); s.route(false, 20); s.route(true, 200);
  assert.deepEqual(s.advance(500), []);
  assert.deepEqual(s.advance(850), ['paste']);
  assert.equal(s.route(false, 900).action, '');
  assert.deepEqual(s.advance(1200), []);
});

test('cancel, inactive focus, changed device and changed settings discard pending single/long', () => {
  for (const held of [false, true]) for (const change of ['cancel', 'inactive', 'device', 'settings']) {
    const s = gestures(); s.route(true, 0); if (!held) s.route(false, 20);
    if (change === 'cancel') s.policy.cancel();
    if (change === 'settings') s.profile.doubleActions[0] = 'undo';
    assert.deepEqual(s.advance(1000, change !== 'inactive', change === 'device' ? 18 : 17), [], change);
    assert.equal(s.policy.hasPending(), false);
  }
});

test('original single with a gesture override is an atomic tap, never a partial upstream lease', () => {
  const s = gestures('original', 'copy', 'disabled', 2067);
  assert.equal(s.route(true, 0).consume, true); assert.equal(s.route(false, 20).consume, true);
  assert.deepEqual(s.advance(300), ['original:2067']);
});

test('voice stays untouched until learned; reserved keys cannot be persisted as voice', () => {
  const p = new TvRemoteKeyPolicy(), profile = defaultTvRemoteKeyProfile();
  profile.actions[5] = 'copy';
  for (const code of [2722, 9, 1, 2, 16, 17, 18, 22, 2017]) {
    assert.deepEqual(plain(p.route(code, 17, true, true, 17, profile, 1000)), none);
    assert.deepEqual(plain(p.route(code, 17, false, true, 17, profile, 1030)), none);
  }
  profile.voiceKeyCode = 2722;
  assert.equal(p.route(2722, 17, true, true, 17, profile, 1100).action, 'copy');
  assert.equal(p.route(2722, 88, true, true, 17, profile, 1200).consume, false);
  for (const code of [1, 2, 16, 17, 18, 22, 2017, 2708]) {
    assert.equal(parseTvRemoteKeyProfile(JSON.stringify({ ...profile, voiceKeyCode: code })).voiceKeyCode, -1);
  }
});

test('voice learning requires a paired real candidate on the bound remote, never a lone Up', () => {
  api.hilog = { info() {} }; api.RD_DOMAIN = 0; api.RD_TAG = 'test';
  const { h } = harness(); h.mateTvDisplayOpen = true; h.mateTvVoiceLearning = true;
  h.mateTvSaveRemoteKeys = () => h.mateTvCancelVoiceLearning();
  const event = (code, device, down) => ({ keyCode: code, deviceId: device, type: down ? 0 : 1, stopPropagation() {} });
  for (const code of [1, 2, 16, 17, 18, 22, 2017]) assert.equal(h.mateTvLearnVoiceKey(event(code, 17, true)), false);
  assert.equal(h.mateTvLearnVoiceKey(event(2722, 88, true)), false);
  h.mateTvLearnVoiceKey(event(2722, 17, false)); assert.equal(h.mateTvRemoteKeys.voiceKeyCode, -1);
  h.mateTvLearnVoiceKey(event(2722, 17, true)); h.mateTvLearnVoiceKey(event(9, 17, false));
  assert.equal(h.mateTvRemoteKeys.voiceKeyCode, -1);
  h.mateTvLearnVoiceKey(event(2722, 17, false));
  assert.equal(h.mateTvRemoteKeys.voiceKeyCode, 2722);
  assert.equal(h.mateTvVoiceLearning, false);
});

test('cancelled gesture timer cannot execute even if an already queued callback runs', () => {
  let now = 0, callback;
  api.Date = { now: () => now }; api.setTimeout = fn => { callback = fn; return 1; };
  const { h, calls, event } = harness();
  h.mateTvRemoteKeys.doubleActions[0] = 'paste';
  h.mateTvRouteRemoteKey(event(true)); now = 20; h.mateTvRouteRemoteKey(event(false));
  assert.equal(typeof callback, 'function'); const stale = callback;
  h.mateTvCancelRemoteKeys(); now = 1000; stale();
  assert.equal(calls.length, 0); assert.equal(h.mateTvRemoteGestureTimer, -1);
});

test('gesture timer rechecks actual foreground ownership before long action', () => {
  let now = 0, callback;
  api.Date = { now: () => now }; api.setTimeout = fn => { callback = fn; return 1; };
  const { h, calls, event } = harness();
  h.mateTvRemoteKeys.longActions[0] = 'paste'; h.mateTvRouteRemoteKey(event(true));
  h.remoteKeyboardForeground = () => false; now = 1000; callback();
  assert.equal(calls.length, 0); assert.equal(h.mateTvRemoteGestureTimer, -1);
  h.remoteKeyboardForeground = () => true; h.mateTvRouteRemoteKey(event(false));
  assert.equal(calls.length, 0);
});

test('menu can open local settings/dictation or toggle fit without sending computer keys', () => {
  api.Date = { now: () => 1000 };
  for (const action of ['open-settings', 'open-dictation', 'toggle-fit']) {
    const { h, calls } = harness(); const local = [];
    h.mateTvOpenDisplay = () => local.push('settings');
    h.mateTvOpenText = () => local.push('dictation');
    h.mateTvSetViewFill = fill => local.push(fill);
    h.mateTvViewCanX = true; h.mateTvViewCanY = false;
    h.mateTvRemoteKeys.actions[4] = action;
    dispatchThroughOwners(h, 2067, 17, true); dispatchThroughOwners(h, 2067, 17, false);
    assert.deepEqual(local, [action === 'open-settings' ? 'settings' : action === 'open-dictation' ? 'dictation' : false]);
    assert.deepEqual(calls, []);
    h.keyboardImeActive = true;
    dispatchThroughOwners(h, 2067, 17, true); dispatchThroughOwners(h, 2067, 17, false);
    assert.equal(local.length, 1);
  }
});

test('lifecycle cancellation also invalidates outstanding device and voice capture', () => {
  const { h } = harness();
  h.mateTvRemoteCapturing = true; h.mateTvVoiceLearning = true;
  const captureGeneration = h.mateTvRemoteCaptureGeneration;
  const voiceGeneration = h.mateTvVoiceGeneration;
  h.mateTvCancelRemoteKeys();
  assert.equal(h.mateTvRemoteCapturing, false); assert.equal(h.mateTvVoiceLearning, false);
  assert.ok(h.mateTvRemoteCaptureGeneration > captureGeneration);
  assert.ok(h.mateTvVoiceGeneration > voiceGeneration);
});

function physicalEvent(code, down, timestamp, device = 17) {
  return { keyCode: code, deviceId: device, type: down ? api.KeyType.Down : api.KeyType.Up,
    timestamp, stopped: 0, stopPropagation() { this.stopped++; } };
}

test('page-only menu event binds a remote without any direction-key event', async () => {
  api.inputDevice = { getDeviceInfo: async id => ({ id, name: 'Remote', vendor: 1, product: 2, uniq: 'remote-unique' }) };
  const { h } = harness(); const focus = [];
  h.getUIContext = () => ({ getFocusController: () => ({ isActive: () => false,
    activate: (...args) => focus.push(['active', ...args]), requestFocus: id => focus.push(['focus', id]) }) });
  h.mateTvDisplayOpen = true; h.mateTvRemoteDeviceId = -1;
  h.sessionInputOwner.visible('MateTvDisplay', true);
  h.mateTvStartRemoteCapture();
  assert.equal(h.mateTvPageRemoteKey(physicalEvent(2067, true, 1, 8)), true);
  await Promise.resolve();
  assert.equal(h.mateTvRemoteCandidate.id, 8);
  assert.equal(h.mateTvRemoteSelectedKey, 4);
  h.mateTvPageRemoteKey(physicalEvent(2067, false, 2, 8));
  h.mateTvSaveRemoteKeys = () => h.mateTvCancelRemoteKeys();
  h.mateTvConfirmRemoteBinding();
  assert.equal(h.mateTvRemoteDeviceId, 8);
  assert.deepEqual(focus, [['focus', 'MateTvRemoteBinding'], ['active', true, false], ['active', false, true]]);
});

test('root menu fallback performs a bound action without a surface key callback', () => {
  const { h, calls } = harness(); h.mateTvRemoteKeys.actions[4] = 'enter';
  assert.equal(h.mateTvPageRemoteKey(physicalEvent(2067, true, 101)), true);
  assert.equal(h.mateTvPageRemoteKey(physicalEvent(2067, false, 102)), true);
  assert.deepEqual(calls, [['tap', 2054, 'enter']]);
});

test('surface and root delivery of the same native event execute once, including a delayed bubble', () => {
  let now = 0; api.Date = { now: () => now };
  const { h, calls } = harness(); h.mateTvRemoteKeys.actions[4] = 'arrow-up';
  const down = physicalEvent(2067, true, 201), up = physicalEvent(2067, false, 202);
  assert.equal(h.mateTvRouteRemoteKey(down), true);
  now = 100; assert.equal(h.mateTvPageRemoteKey({ ...down, stopped: 0 }), true);
  assert.equal(h.mateTvRouteRemoteKey(up), true);
  now = 200; assert.equal(h.mateTvPageRemoteKey({ ...up, stopped: 0 }), true);
  assert.deepEqual(calls, [['tap', 2012, 'arrow-up']]);
  // A genuine subsequent physical dispatch has another timestamp and must work.
  h.mateTvPageRemoteKey(physicalEvent(2067, true, 203));
  h.mateTvPageRemoteKey(physicalEvent(2067, false, 204));
  assert.equal(calls.length, 2);
});

test('root fallback leaves ordinary keyboard Down/Up leases untouched and excludes another device', () => {
  const { h, calls } = harness(); h.mateTvRemoteKeys.actions[4] = 'enter';
  for (const code of [2017, 2067]) {
    const down = physicalEvent(code, true, code, 88), up = physicalEvent(code, false, code + 1, 88);
    assert.equal(h.mateTvRouteRemoteKey(down), false);
    assert.equal(h.sessionInputOwner.allowsPhysical(code, true), true);
    assert.equal(h.mateTvPageRemoteKey(down), false);
    assert.equal(h.mateTvRouteRemoteKey(up), false);
    assert.equal(h.sessionInputOwner.allowsPhysical(code, false), true);
    assert.equal(h.mateTvPageRemoteKey(up), false);
  }
  assert.equal(calls.length, 0);
});

test('new modal epochs stop root learning and prevent late discovery or confirmation', async () => {
  let resolve;
  api.inputDevice = { getDeviceInfo: () => new Promise(done => { resolve = done; }) };
  const { h, calls } = harness(); h.mateTvDisplayOpen = true;
  h.sessionInputOwner.visible('MateTvDisplay', true);
  h.mateTvRemoteLearningEpoch = h.sessionInputOwner.epoch(); h.mateTvRemoteCapturing = true;
  h.mateTvPageRemoteKey(physicalEvent(2067, true, 300));
  const auth = h.sessionInputOwner.acquire('Auth', 'system');
  resolve({ id: 17, name: 'Remote', vendor: 1, product: 2, uniq: 'remote-unique' });
  await Promise.resolve();
  assert.equal(h.mateTvRemoteCandidate, null);
  assert.equal(h.mateTvPageRemoteKey(physicalEvent(2067, false, 301)), false);
  assert.equal(h.mateTvRemoteCapturing, false);
  h.sessionInputOwner.release(auth);
  assert.equal(h.mateTvPageRemoteKey(physicalEvent(2067, true, 302)), false);
  assert.equal(calls.length, 0);
});

test('root routing respects runtime KeyType constants instead of assuming numeric event order', () => {
  const previous = api.KeyType; api.KeyType = { Down: 1, Up: 0 };
  try {
    const { h, calls } = harness(); h.mateTvRemoteKeys.actions[4] = 'enter';
    h.mateTvPageRemoteKey(physicalEvent(2067, true, 400));
    h.mateTvPageRemoteKey(physicalEvent(2067, false, 401));
    assert.deepEqual(calls, [['tap', 2054, 'enter']]);
  } finally { api.KeyType = previous; }
});

test('remote key diagnostics persist bounded metadata, throttle repeats and never record editor or letter events', () => {
  let now = 1000; api.Date = { now: () => now };
  const storage = new Map([['remoteMenu', JSON.stringify(['previous-session'])]]); let writes = 0;
  api.preferences = { getPreferencesSync: (_ctx, options) => {
    assert.equal(options.name, 'ScreenLinkInputDiagnostics');
    return { getSync: (key, fallback) => storage.get(key) ?? fallback,
      putSync: (key, value) => { writes++; storage.set(key, value); }, flushSync() {} };
  } };
  const { h } = harness();
  const menu = physicalEvent(2067, true, 900, 8); menu.keyText = 'MUST_NOT_PERSIST';
  h.mateTvRemoteKeyDiagnostic(menu, 'page');
  assert.equal(writes, 1); assert.equal(JSON.parse(storage.get('remoteMenu'))[0], 'previous-session');
  now += 20; h.mateTvRemoteKeyDiagnostic(menu, 'page'); assert.equal(writes, 1);
  h.mateTvRemoteKeyDiagnostic(physicalEvent(2067, false, 901, 8), 'page'); assert.equal(writes, 2);
  h.mateTvRemoteKeyDiagnostic(physicalEvent(2017, true, 902), 'page');
  h.mateTvRemoteKeyDiagnostic(physicalEvent(2012, true, 903, 88), 'page'); assert.equal(writes, 2);
  h.keyboardOpen = true; h.mateTvRemoteKeyDiagnostic(menu, 'page'); assert.equal(writes, 2); h.keyboardOpen = false;
  for (let i = 0; i < 40; i++) { now += 300; h.mateTvRemoteKeyDiagnostic(menu, 'page'); }
  const lines = JSON.parse(storage.get('remoteMenu'));
  assert.equal(lines.length, 32); assert.ok(lines.every(line => line.includes('phase=down') && line.includes('device=8')));
  assert.ok(lines.every(line => !line.includes('MUST_NOT_PERSIST')));
  h.mateTvRemoteKeyDiagnostic(physicalEvent(2012, true, 904, 17), 'surface');
  assert.match(JSON.parse(storage.get('remoteMenu')).at(-1), /code=2012.*keyDown=0 keyUp=1 device=17/);
});
