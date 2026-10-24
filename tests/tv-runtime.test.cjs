// Run after prepare_client.py with Node 24+: node --test tests/tv-runtime.test.cjs
// Execute the actual TV handlers and pinned upstream Mac transaction methods.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const root = require('node:path').resolve(__dirname, '..');
const read = path => readFileSync(root + '/' + path, 'utf8');
const session = read('.work/client/entry/src/main/ets/pages/RemoteDesktop.ets');
const policy = read('.work/client/entry/src/main/ets/services/RemotePointerFocusPolicy.ets');
const wheelPolicy = read('.work/client/entry/src/main/ets/services/RemoteWheelPolicy.ets');
const wheelDirection = wheelPolicy.slice(wheelPolicy.indexOf('export function applyRemoteWheelDirection('), wheelPolicy.indexOf('\n}', wheelPolicy.indexOf('export function applyRemoteWheelDirection(')) + 2);
const scrollPolicy = read('.work/client/entry/src/main/ets/services/RemoteScrollPolicy.ets');
const fragment = read('tv/fragments/session-members.ets').split('  @Builder')[0];
const lifecycle = read('tv/fragments/lifecycle-members.ets').split('  @Builder')[0] + read('tv/fragments/resume-members.ets');
const transaction = session.slice(session.indexOf('  private clearPhysicalMouseClickTransaction()'),
  session.indexOf('  /**\n   * Native CONNECTED'));
function create(layout = 'macos') {
  let now = 10000;
  const context = vm.createContext({
    Date: { now: () => now },
    deviceInfo: { deviceType: 'tv' },
    SourceTool: { MOUSE: 7, Finger: 1 }, SourceType: { Mouse: 2, KEY: 4, JOYSTICK: 5 },
    TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 },
    MouseAction: { Press: 1, Release: 2 }, MouseButton: { Left: 1 },
    TextAreaController: class { stopEditing() {} }, KeyType: { Down: 0, Up: 1 },
    hilog: { info() {}, warn() {} }, RD_DOMAIN: 0, RD_TAG: 'test',
    router: { back() { context.returns++; } }, returns: 0,
  });
  const wheel = session.slice(session.indexOf('  private sendTouchPadWheel('), session.indexOf('  private sendRemoteKeyTap('));
  const source = policy.replace(/export /g, '') + wheelDirection.replace(/export /g, '') + scrollPolicy.replace(/export /g, '') + '\nclass Harness {\n' +
    fragment.replace(/@State /g, '') + transaction + wheel + lifecycle.replace(/@State /g, '') +
    '\n}\nglobalThis.Harness = Harness;';
  vm.runInContext(stripTypeScriptTypes(source), context);
  const page = new context.Harness();
  const events = [];
  Object.assign(page, {
    rustdeskTouchpadSpeed: 1, touchWheelSendCount: 0,
    isVncSession() { return false; }, reverseWheelForCurrentProtocol() { return false; },
    wheelSpeedForCurrentProtocol() { return 100; },
    scrollWireForSession() { return layout === 'macos' ? 'pixels' : 'units'; },
    toSourceSpace(x,y) { return {x,y}; },
    sendScrollSteps(x,y,amount,wire) { events.push(['wheel', x,y,amount,wire]); return true; },
    physicalKeyboardLayout: layout, connectAttemptId: 1, sessionId: 10,
    physicalMouseClickPending: false, physicalMouseRemoteDownSent: false,
    physicalMouseButtonsDown: [], remoteMouseButtonsDown: [],
    remoteCursorX: 0, remoteCursorY: 0, pending: null, allowed: true,
    canForwardInput() { return this.allowed; }, currentProtocolName() { return 'rustdesk'; },
    mapInputPoint(x, y) { return { x, y, inside: x >= 0 && y >= 0 }; },
    rememberRemoteCursor(x, y) { this.remoteCursorX = x; this.remoteCursorY = y; },
    discardPendingMouseMove() { this.pending = null; },
    queueMouseMove(x, y) { this.pending = [x, y]; },
    flushMouseMove() {
      if (this.pending && !this.physicalMouseClickPending || this.pending && this.physicalMouseRemoteDownSent) {
        events.push(['move', ...this.pending]); this.rememberRemoteCursor(...this.pending); this.pending = null;
      }
    },
    sendMouseNow(x, y, button, down) {
      if (!this.allowed) return;
      events.push([down ? 'down' : 'up', x, y, button]);
      this.rememberRemoteCursor(x, y);
      this.remoteMouseButtonsDown = down ? [button] : [];
    },
    releaseTrackedMouseButtons() {
      for (const b of this.remoteMouseButtonsDown) events.push(['up', this.remoteCursorX, this.remoteCursorY, b]);
      this.remoteMouseButtonsDown = []; this.clearPhysicalMouseClickTransaction();
    },
  });
  function touch(type, x = 100, y = 100, id = 1) {
    page.mateTvTouch({ type, sourceTool: 1, source: 1,
      changedTouches: [{ x, y, id }], stopPropagation() {} });
  }
  return { page, events, touch, context, advance(ms) { now += ms; } };
}
test('Mac tap tolerates small sensor motion and sends exactly one click at press target', () => {
  const { page, events, touch } = create();
  touch(0); touch(2, 101, 101); touch(2, 102, 100);
  assert.deepEqual(events, []);
  touch(1, 102, 100);
  page.mateTvClick(102, 100);
  assert.deepEqual(events, [['down', 100, 100, 0], ['up', 100, 100, 0]]);
});
test('Mac held motion crosses drag threshold and releases at final target', () => {
  const { events, touch, advance } = create();
  touch(0); advance(350); touch(2, 120, 110); touch(2, 150, 130); touch(1, 160, 140);
  assert.equal(events[0][0], 'down');
  assert.deepEqual(events[0].slice(1), [100, 100, 0]);
  assert.equal(events.filter(e => e[0] === 'down').length, 1);
  assert.deepEqual(events.at(-1), ['up', 160, 140, 0]);
});
test('Windows stages touch until release so a swipe never presses a button', () => {
  const { events, touch } = create('windows');
  touch(0); assert.deepEqual(events, []);
  touch(1); assert.equal(events.length, 2);
});
test('Cancel before a Mac drag cannot create an accidental click', () => {
  const { events, touch } = create(); touch(0); touch(3); touch(1);
  assert.deepEqual(events, []);
});
test('Cancel after a drag releases the held button even when input is blocked', () => {
  const { page, events, touch, advance } = create(); touch(0); advance(350); touch(2, 120, 110);
  page.allowed = false; touch(3); touch(1);
  assert.equal(events.filter(e => e[0] === 'up').length, 1);
  assert.equal(page.mateTvTouchId, -1);
});
test('A second finger cannot release the primary contact', () => {
  const { events, touch } = create(); touch(0); touch(0, 200, 200, 2); touch(1, 200, 200, 2);
  assert.deepEqual(events, []); touch(1); assert.equal(events.length, 2);
});
test('Leaving waits for native completion and repeated back cannot start another teardown', () => {
  const { page, context } = create(); let teardowns = 0;
  page.mateTvStopJoystick = () => {}; page.mateTvCloseText = () => {}; page.mateTvCloseDisplay = () => {};
  page.disconnectAndCleanup = () => { teardowns++; page.cleanupStarted = true; };
  page.mateTvLeaveSession(); page.mateTvLeaveSession();
  assert.equal(teardowns, 1); assert.equal(context.returns, 0);
  page.mateTvFinishLeave(); page.mateTvFinishLeave();
  assert.equal(context.returns, 1);
});

test('TV synthesized tap without raw down/up produces a click', () => {
  const { page, events } = create();
  page.mateTvActivate({ source: 2, x: 120, y: 90 });
  assert.deepEqual(events, [['down', 120, 90, 0], ['up', 120, 90, 0]]);
});
test('A real touch followed by its tap recognizer never clicks twice', () => {
  const { page, events, touch } = create(); touch(0); touch(1);
  page.mateTvActivate({ source: 1, x: 100, y: 100 });
  assert.equal(events.length, 2);
});

const canvasPolicy = read('.work/client/entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets');
const viewportFragment = read('tv/fragments/viewport-members.ets').split('  @Builder')[0];
function createViewport(width, height, surfaceWidth = 1920, surfaceHeight = 1080) {
  const defaultMethod = session.slice(session.indexOf('  private currentCanvasDisplayDefault('),
    session.indexOf('  private refreshCanvasTransformModified('));
  const rebaseMethod = session.slice(session.indexOf('  private rebaseManualCanvasForSourceGeometry('),
    session.indexOf('  /** Disabling local canvas zoom'));
  const context = vm.createContext({ setInterval() { return 1; }, clearInterval() {} });
  vm.runInContext(stripTypeScriptTypes(canvasPolicy.replace(/export /g, '') + '\nclass Viewport {\n' +
    viewportFragment.replace(/@State /g, '') + defaultMethod + rebaseMethod +
    '\n}\nglobalThis.Viewport = Viewport;'), context);
  const page = new context.Viewport();
  const viewport = { surfaceWidth, surfaceHeight, sourceWidth: width, sourceHeight: height };
  Object.assign(page, {
    mateTvMode: true, mateTvTextOpen: false, mateTvDisplayOpen: false, rustDeskDisplaySwitchState: { inputBlocked: false },
    connected: true, cleanupStarted: false, canvasRotationQuarterTurns: 0,
    currentCanvasViewport() { return viewport; }, refreshCanvasTransformModified() {},
    applyCanvasTransform() { this.mateTvSyncViewport(viewport); },
    mateTvCancelDrag() {},
    resetCanvasToDisplayDefault() {
      this.canvasTransform = this.currentCanvasDisplayDefault(viewport); this.applyCanvasTransform();
    },
    sendMouseNow() { throw Error('View panning must never move the remote mouse'); },
  });
  page.resetCanvasToDisplayDefault();
  return { page, viewport };
}
function close(actual, expected) { assert.ok(Math.abs(actual - expected) < 0.01, `${actual} != ${expected}`); }
test('Portrait fills width; vertical slider endpoints expose top and bottom without blank edges', () => {
  const { page, viewport: v } = createViewport(1080, 1920);
  const scale = Math.min(v.surfaceWidth / v.sourceWidth, v.surfaceHeight / v.sourceHeight) * page.canvasTransform.scale;
  close(v.sourceWidth * scale, v.surfaceWidth);
  assert.equal(page.mateTvViewCanX, false); assert.equal(page.mateTvViewCanY, true);
  page.mateTvMoveViewportPixels(0, -1e9);
  close((v.surfaceHeight - v.sourceHeight * scale) / 2 + page.canvasTransform.panY, 0);
  page.mateTvMoveViewportPixels(0, 1e9);
  close((v.surfaceHeight + v.sourceHeight * scale) / 2 + page.canvasTransform.panY, v.surfaceHeight);
});
test('32:9 fills height; horizontal slider endpoints reveal both source edges', () => {
  const { page, viewport: v } = createViewport(5120, 1440);
  const scale = Math.min(v.surfaceWidth / v.sourceWidth, v.surfaceHeight / v.sourceHeight) * page.canvasTransform.scale;
  close(v.sourceHeight * scale, v.surfaceHeight);
  assert.equal(page.mateTvViewCanX, true); assert.equal(page.mateTvViewCanY, false);
  page.mateTvMoveViewportPixels(-1e9, 0);
  close((v.surfaceWidth - v.sourceWidth * scale) / 2 + page.canvasTransform.panX, 0);
  page.mateTvMoveViewportPixels(1e9, 0);
  close((v.surfaceWidth + v.sourceWidth * scale) / 2 + page.canvasTransform.panX, v.surfaceWidth);
});
test('16:9 has no overflow; fit and text panel preserve complete portrait image', () => {
  const normal = createViewport(3840, 2160).page;
  assert.equal(normal.mateTvViewCanX, false); assert.equal(normal.mateTvViewCanY, false);
  const { page } = createViewport(1080, 1920, 1305, 600);
  page.mateTvSetViewFill(false);
  close(page.canvasTransform.scale, 1); assert.equal(page.mateTvViewCanY, false);
  page.mateTvSetViewFill(true); page.mateTvTextOpen = true; page.resetCanvasToDisplayDefault();
  close(page.canvasTransform.scale, 1); assert.equal(page.mateTvViewCanY, false);
  const before = JSON.stringify(page.canvasTransform);
  page.mateTvMoveViewportPixels(0, 1e9);
  assert.equal(JSON.stringify(page.canvasTransform), before);
});
test('Changing display geometry resets the pan axis and center', () => {
  const { page, viewport } = createViewport(5120, 1440);
  page.mateTvMoveViewportPixels(1e9, 0);
  page.canvasTransformGestureModified = true;
  page.rebaseManualCanvasForSourceGeometry(5120, 1440, 1080, 1920);
  assert.equal(page.canvasTransformGestureModified, false);
  viewport.sourceWidth = 1080; viewport.sourceHeight = 1920;
  page.resetCanvasToDisplayDefault();
  assert.equal(page.mateTvViewCanX, false); assert.equal(page.mateTvViewCanY, true);
  close(page.canvasTransform.panX, 0); close(page.canvasTransform.panY, 0);
});

test('Independent semantic activations are not suppressed by a consumed raw duplicate', () => {
  const { page, events, touch } = create(); touch(0); touch(1);
  page.mateTvActivate({ source: 1, x: 100, y: 100 });
  page.mateTvActivate({ source: 1, x: 100, y: 100 });
  assert.equal(events.length, 4);
});
test('Remote confirm activation targets the last pointer position', () => {
  const { page, events } = create();
  page.mateTvPointerX = 140; page.mateTvPointerY = 80;
  page.mateTvActivate({ source: 4, x: 0, y: 0 });
  assert.deepEqual(events, [['down', 140, 80, 0], ['up', 140, 80, 0]]);
});

test('Native pixels avoid enlargement and retain a horizontal dock for an ultrawide source', () => {
  const { page, viewport: v } = createViewport(5120, 1440, 3840, 2160);
  page.mateTvSetViewNative();
  const fit = Math.min(v.surfaceWidth / v.sourceWidth, v.surfaceHeight / v.sourceHeight);
  close(page.canvasTransform.scale * fit, 1);
  assert.equal(page.mateTvViewCanX, true); assert.equal(page.mateTvViewCanY, false);
  page.mateTvMoveViewportPixels(1e9, 0);
  close(page.canvasTransform.panX, -640);
});

test('Joystick stays bounded, pans continuously and returns to center without moving desktop objects', () => {
  const { page } = createViewport(5120, 1440);
  page.mateTvStartJoystick({ offsetX: 300, offsetY: 0 });
  close(page.mateTvJoystickX, 30);
  page.mateTvJoystickAt = 1000; page.mateTvTickJoystick(1020);
  assert.ok(page.canvasTransform.panX < 0);
  const position = page.canvasTransform.panX;
  page.mateTvStopJoystick(); page.mateTvTickJoystick(1040);
  close(page.canvasTransform.panX, position); close(page.mateTvJoystickX, 0);
  page.mateTvStartJoystick({ offsetX: -20, offsetY: 0 }); page.mateTvTextOpen = true;
  page.mateTvTickJoystick(1060);
  assert.equal(page.mateTvJoystickTimer, -1); close(page.canvasTransform.panX, position);
});

test('TV startup restores saved streaming preferences after migration and respects later user changes', () => {
  const saved = new Map([['mateTvStreamDefaultsV2', true], ['rustdeskCodec', 5],
    ['rustdeskImageQuality', 2], ['fps', 30]]);
  const storage = new Map();
  const resolutions = [];
  const context = vm.createContext({
    preferences: { getPreferencesSync() { return {
      getSync(key, fallback) { return saved.has(key) ? saved.get(key) : fallback; },
      putSync(key, value) { saved.set(key, value); }, flushSync() {},
    }; } }, getContext() {}, RUSTDESK_FPS_PREF_KEY: 'fps',
    normalizeRustDeskFps(value) { return value; },
    AppStorage: { setOrCreate(key, value) { storage.set(key, value); } },
    hilog: { info() {} }, RD_DOMAIN: 0, RD_TAG: 'test',
    rdpnapi: { getHardwareVideoDecoderCapabilities() { return {}; }, setMateTvSourceResolution(source) { resolutions.push(source); return true; } },
  });
  const fragment = read('tv/fragments/display-members.ets').split('  @Builder')[0];
  vm.runInContext(stripTypeScriptTypes('class Prefs {\n' + fragment.replace(/@State /g, '') +
    '\n}\nglobalThis.Prefs = Prefs;'), context);
  const page = new context.Prefs(); page.mateTvMode = true;
  page.mateTvInitStreamDefaults();
  assert.equal(storage.get('rustdeskCodec'), 5); assert.equal(storage.get('rustdeskImageQuality'), 2);
  assert.equal(storage.get('fps'), 60);
  saved.set('fps', 120);
  saved.set('rustdeskImageQuality', 1); saved.set('rustdeskCodec', 2);
  page.mateTvInitStreamDefaults();
  assert.equal(storage.get('rustdeskImageQuality'), 1); assert.equal(storage.get('rustdeskCodec'), 2);
  assert.deepEqual(resolutions, [true, true]);
  page.mateTvSetSourceResolution(false);
  assert.equal(saved.get('rustdeskImageQuality'), 1);
  assert.equal(saved.get('mateTvSourceResolution'), false);
  saved.set('rustdeskImageQuality', 0);
  page.mateTvInitStreamDefaults();
  assert.equal(page.mateTvSourceResolution, false);
  assert.equal(resolutions.at(-1), false);
  assert.equal(storage.get('rustdeskImageQuality'), 0);
  assert.equal(storage.get('fps'), 120);
});


test('TV panel ownership is idempotent and closing retires only its own leases', () => {
  const ownerSource = read('.work/client/entry/src/main/ets/services/RemoteSessionInputOwner.ets');
  const display = read('tv/fragments/display-members.ets').split('  @Builder')[0];
  const context = vm.createContext({
    hilog: { info() {} }, RD_DOMAIN: 0, RD_TAG: 'test',
    setInterval() { return 1; }, clearInterval() {},
  });
  vm.runInContext(stripTypeScriptTypes(ownerSource.replace(/export /g, '') +
    '\nclass Panels {\n' + display.replace(/@State /g, '') +
    '\n}\nglobalThis.Panels = Panels; globalThis.Owner = RemoteSessionInputOwner;'), context);
  const page = new context.Panels();
  page.sessionInputOwner = new context.Owner();
  let cancelledRemoteCaptures = 0;
  Object.assign(page, { connected: true, cleanupStarted: false, mateTvStopJoystick() {},
    mateTvCancelRemoteCapture() { cancelledRemoteCaptures++; }, mateTvCancelVoiceLearning() {},
    mateTvCloseText() {}, mateTvCancelDrag() {}, releaseRustDeskInputBeforeBlock() {}, mateTvRefreshStreamStatus() {} });
  page.mateTvOpenDisplay(); page.mateTvOpenDisplay();
  page.mateTvCloseDisplay();
  assert.equal(page.sessionInputOwner.blocked(), false);
  assert.equal(cancelledRemoteCaptures, 1);
  // Simulate old duplicate leases, and an unrelated authentication dialog.
  page.sessionInputOwner.appeared('MateTvDisplay'); page.sessionInputOwner.appeared('MateTvDisplay');
  const auth = page.sessionInputOwner.acquire('Auth', 'system');
  page.mateTvCloseDisplay(); page.mateTvCloseDisplay();
  assert.equal(cancelledRemoteCaptures, 3);
  assert.equal(page.sessionInputOwner.blocked(), true);
  assert.equal(page.sessionInputOwner.debugString().includes('MateTvDisplay'), false);
  page.sessionInputOwner.release(auth);
  assert.equal(page.sessionInputOwner.blocked(), false);
});


for (const layout of ['macos', 'windows']) {
  test(`${layout} quick swipe sends wheel only, never turns into drag after a pause`, () => {
    const { page, events, touch, advance } = create(layout);
    touch(0); advance(40); touch(2,100,80); advance(500); touch(2,100,60); touch(1,100,60);
    page.mateTvActivate({source:1,x:100,y:60});
    assert.equal(events.filter(e => e[0] === 'down' || e[0] === 'up').length, 0);
    assert.equal(events.length, 2);
    assert.equal(events[0][0], 'wheel'); assert.ok(events[0][3] < 0);
    assert.equal(events[0][4], layout === 'macos' ? 'pixels' : 'units');
  });
}
test('Gesture cancellation releases input and the next tap still works', () => {
  const { page, events, touch, advance } = create();
  touch(0); advance(400); touch(2,120,100); page.mateTvCancelDrag();
  touch(1,120,100); touch(0); touch(1);
  assert.equal(events.filter(e => e[0] === 'down').length, 2);
  assert.equal(events.filter(e => e[0] === 'up').length, 2);
  assert.equal(page.mateTvTouchGesture, 'idle');
});
test('Physical mouse and real wheel input remain owned by upstream handlers', () => {
  const { page, events } = create();
  assert.equal(page.mateTvObserveMouse({x:100,y:100,sourceTool:7,action:1,button:1}), false);
  page.mateTvTouch({type:0,sourceTool:7,source:2,changedTouches:[{x:100,y:100,id:1}]});
  assert.deepEqual(events, []); assert.equal(page.mateTvTouchId, -1);
});

for (const layout of ['macos', 'windows']) {
  test(`${layout}: stationary long press releases one right click, never a left click`, () => {
    const { page, events, touch, advance } = create(layout);
    touch(0); advance(650); touch(2, 102, 101);
    assert.deepEqual(events, []);
    touch(1, 102, 101); page.mateTvClick(102, 101);
    assert.deepEqual(events, [['down', 100, 100, 2], ['up', 100, 100, 2]]);
  });
  test(`${layout}: long hold followed by movement only drags, cancel never right clicks`, () => {
    const { events, touch, advance } = create(layout);
    touch(0); advance(700); touch(2, 120, 110); touch(1, 140, 130);
    assert.deepEqual(events[0], ['down', 100, 100, 0]);
    assert.deepEqual(events.at(-1), ['up', 140, 130, 0]);
    assert.equal(events.some(e => e[3] === 2), false);
    events.length = 0; touch(0); advance(700); touch(3); touch(1);
    assert.deepEqual(events, []);
  });
}

test('Unified dock migrates preferences, keeps one corner and previews the actual controls', () => {
  const saved = new Map([['mateTvToolsCorner', 1], ['mateTvToolsHorizontal', true]]);
  const context = vm.createContext({ preferences: { getPreferencesSync() { return {
    getSync(key, fallback) { return saved.has(key) ? saved.get(key) : fallback; },
    putSync(key, value) { saved.set(key, value); }, flushSync() {},
  }; } }, getContext() {} });
  const source = read('tv/fragments/corner-controls.ets').split('  @Builder')[0].replace(/@State /g, '');
  vm.runInContext(stripTypeScriptTypes('class Dock {\n' + source + '\n}\nglobalThis.Dock = Dock'), context);
  const page = new context.Dock();
  const screens = [{ display: 3, online: true }, { display: 7, online: false }, { display: 9, online: true }];
  Object.assign(page, { surfaceWidth: 1280, surfaceHeight: 720, connected: true,
    mateTvViewCanX: false, mateTvViewCanY: false, mateTvViewHasAlternatives: false,
    mateTvStopJoystick() {}, mateTvCancelDrag() {},
    rustDeskDisplaySwitchState: { inputBlocked: false },
    rustDeskDisplayCapabilities: { displays: screens, currentDisplay: 3 },
    selectRustDeskDisplay(screen) { this.rustDeskDisplayCapabilities.currentDisplay = screen.display; },
  });
  page.mateTvMeasureControlsRoot({width: 1280, height: 720});
  page.mateTvLoadControls();
  assert.equal(page.mateTvControlsCorner, 1); assert.equal(page.mateTvControlsHorizontal, true);
  assert.deepEqual(Array.from(page.mateTvControlLabels()), ['设置', '切屏', '听写']);
  for (const overflow of [false, true]) for (let corner = 0; corner < 4; corner++) {
    for (const horizontal of [false, true]) {
      page.mateTvViewCanX = overflow; page.mateTvViewHasAlternatives = overflow;
      page.mateTvSaveControls(corner, horizontal);
      const x = page.mateTvDockX(), y = page.mateTvDockY();
      assert.ok(x >= 0 && y >= 0 && x + page.mateTvDockWidth() <= 1280 && y + page.mateTvDockHeight() <= 720);
      assert.equal(corner % 2 ? x + page.mateTvDockWidth() : x, corner % 2 ? 1256 : 24);
      assert.equal(corner < 2 ? y : y + page.mateTvDockHeight(), corner < 2 ? 24 : 696);
      // Dictation shrinks the canvas and keyboard resizes the page. Closing it
      // must restore all corners even if canvas dimensions are still stale.
      page.surfaceWidth = 870; page.surfaceHeight = 413;
      page.mateTvMeasureControlsRoot({width: 1280, height: 413});
      page.mateTvMeasureControlsRoot({width: 1280, height: 720});
      assert.equal(page.mateTvDockX(), x); assert.equal(page.mateTvDockY(), y);
      page.mateTvMeasureControlsRoot({width: 0, height: 0});
      assert.equal(page.mateTvDockX(), x); assert.equal(page.mateTvDockY(), y);
      const joyX = page.mateTvDockJoystickX(), joyY = page.mateTvDockJoystickY();
      assert.ok(joyX >= 0 && joyY >= 0 && joyX + 112 <= 1280 && joyY + 112 <= 720);
      assert.ok(joyX + 112 <= x || joyX >= x + page.mateTvDockWidth() ||
        joyY + 112 <= y || joyY >= y + page.mateTvDockHeight());
      page.mateTvViewCanX = !overflow; // same small buttons, joystick visibility changes
      assert.equal(page.mateTvDockX(), x); assert.equal(page.mateTvDockY(), y);
      page.mateTvViewCanX = overflow;
      const previewW = horizontal ? page.mateTvSmallLabels().length * 48 - 6 : 42;
      const previewH = horizontal ? 24 : page.mateTvSmallLabels().length * 30 - 6;
      assert.ok(page.mateTvPreviewX() + previewW <= 360 && page.mateTvPreviewY() + previewH <= 172);
    }
  }
  assert.deepEqual(Array.from(page.mateTvControlLabels()), ['设置', '缩小', '切屏', '听写', '摇杆']);
  page.mateTvViewCanX = false;
  assert.ok(page.mateTvControlLabels().includes('放大'));
  page.mateTvSaveControls(0, true);
  const restored = new context.Dock(); restored.mateTvLoadControls();
  assert.equal(restored.mateTvControlsCorner, 0); assert.equal(restored.mateTvControlsHorizontal, true);
  page.mateTvNextDisplay(); assert.equal(page.rustDeskDisplayCapabilities.currentDisplay, 9);
  page.mateTvNextDisplay(); assert.equal(page.rustDeskDisplayCapabilities.currentDisplay, 3);
  page.rustDeskDisplaySwitchState.inputBlocked = true;
  page.mateTvNextDisplay(); assert.equal(page.rustDeskDisplayCapabilities.currentDisplay, 3);
});

test('Aspect-ratio toggle stays available in fit mode but disappears for matching aspect ratios', () => {
  const normal = createViewport(3840, 2160).page;
  assert.equal(normal.mateTvViewHasAlternatives, false);
  const { page, viewport } = createViewport(5120, 1440);
  assert.equal(page.mateTvViewHasAlternatives, true);
  page.mateTvSetViewFill(false);
  assert.equal(page.mateTvViewHasAlternatives, true);
  assert.equal(page.mateTvViewCanX, false);
  viewport.sourceWidth = 1080; viewport.sourceHeight = 1920;
  page.canvasRotationQuarterTurns = 1;
  page.resetCanvasToDisplayDefault();
  assert.equal(page.mateTvViewHasAlternatives, false);
});

test('TV frame-rate choices accept 120 FPS independently of quality', () => {
  const source = read('tv/overlay/entry/src/main/ets/services/RustDeskFrameRatePolicy.ets');
  const context = vm.createContext({});
  vm.runInContext(stripTypeScriptTypes(source.replace(/export /g, '')), context);
  for (const rate of [30, 60, 120]) {
    assert.equal(context.normalizeRustDeskFps(rate), rate);
    for (const quality of [0, 1, 2]) {
      assert.equal(context.rustDeskFpsLockedByQuality(quality), false);
      assert.equal(context.rustDeskFpsSummary(quality, rate), rate + ' 帧上限');
    }
  }
  assert.equal(context.normalizeRustDeskFps(500), 0);
});

test('Video watchdog recovers continuous ingress without presentation, stays quiet on idle/background and bounds retries', () => {
  let now = 10000;
  const context = vm.createContext({ Date: { now: () => now }, hilog: { warn() {} }, RD_DOMAIN: 0, RD_TAG: 'test' });
  vm.runInContext(stripTypeScriptTypes('class Watchdog {\n' + read('tv/fragments/video-watchdog.ets') + '\n}\nglobalThis.Watchdog = Watchdog;'), context);
  const page = new context.Watchdog();
  const stats = { sessionActive: true, sessionId: 1, decoderGeneration: 1, rendererGeneration: 1,
    width: 1920, height: 1080, receivedFrames: 100, presentedFrames: 100 };
  let refresh = 0, recreate = 0, foreground = true;
  Object.assign(page, { mateTvMode: true, connected: true, sessionId: 1, connectAttemptId: 1,
    surfaceReady: true, mateTvLeaving: false, rustDeskDisplaySwitchState: {inputBlocked: false},
    remoteKeyboardForeground: () => foreground,
    loader: { getSessionDiagnostics: () => stats, requestFrameRefresh() { refresh++; return {ok:true}; },
      requestDecoderRecovery() { recreate++; return true; } } });
  const tick = (receive = true, present = false) => { now += 1000; if (receive) stats.receivedFrames += 60;
    if (present) stats.presentedFrames += 60; page.mateTvCheckVideoProgress(); };
  page.mateTvCheckVideoProgress();
  for(let i=0;i<20;i++) tick(false); // static desktop isn't a freeze
  assert.equal(refresh,0);
  for(let i=0;i<4;i++) tick();
  assert.equal(refresh,1);
  for(let i=0;i<30;i++) tick();
  assert.equal(refresh,2); assert.equal(recreate,1); // no endless rebuild loop
  for(let i=0;i<32;i++) tick(true,true); // sustained recovery re-arms a later incident
  foreground=false;
  for(let i=0;i<12;i++) tick();
  assert.equal(refresh,2);
  foreground=true; tick();
  for(let i=0;i<3;i++) tick();
  assert.equal(refresh,2); // foreground grace period
  tick(); assert.equal(refresh,3);
  stats.sessionId=2;
  for(let i=0;i<12;i++) tick();
  assert.equal(refresh,3); // stale owner's diagnostics cannot recover another session
});

function createLifecycleBarrier() {
  const context = vm.createContext({ hilog: { info() {}, warn() {} }, RD_DOMAIN: 0, RD_TAG: 'test' });
  const detach = session.slice(session.indexOf('  private async detachForBackground()'),
    session.indexOf('  private async performBackgroundDetach()'));
  vm.runInContext(stripTypeScriptTypes('class Lifecycle {\n' + lifecycle.replace(/@State /g, '') +
    detach + '\n}\nglobalThis.Lifecycle = Lifecycle;'), context);
  const page = new context.Lifecycle();
  const events = [];
  let finish, fail;
  const deferred = new Promise((resolve, reject) => { finish = resolve; fail = reject; });
  Object.assign(page, { sessionId: 1, connectAttemptId: 1, connected: true, bgRestorePending: false,
    backgroundDetachPromise: null, background: true,
    currentAbilityBackgroundState() { return this.background; },
    async performBackgroundDetach() {
      this.cleanupStarted = true;
      await deferred;
      events.push('detach'); this.bgRestorePending = true;
    },
    performForegroundRestore() {
      assert.equal(this.backgroundDetachPromise, null);
      events.push('restore'); this.cleanupStarted = false; this.bgRestorePending = false;
    } });
  return { page, events, finish, fail };
}

test('Fast foreground return waits for the actual detach before rebinding and deduplicates callbacks', async () => {
  const {page, events, finish} = createLifecycleBarrier();
  const pending = page.detachForBackground();
  page.background = false;
  // Foreground can arrive even before background init sets bgRestorePending.
  page.restoreFromBackground(); page.restoreFromBackground();
  assert.equal(page.cleanupStarted, true); assert.deepEqual(events, []);
  finish(); await pending; await Promise.resolve();
  assert.deepEqual(events, ['detach', 'restore']);
  assert.equal(page.bgRestorePending, false);
});

test('A backgrounded, replaced, leaving or handed-off session cannot be restored by an old detach', async () => {
  for (const change of [p => p.background = true, p => p.sessionId++, p => p.connectAttemptId++,
    p => p.mateTvLeaving = true, p => p.connected = false, p => p.pcWindowHandoffComplete = true]) {
    const {page, events, finish} = createLifecycleBarrier();
    const pending = page.detachForBackground();
    page.background = false; page.restoreFromBackground(); change(page);
    finish(); await pending; await Promise.resolve();
    assert.deepEqual(events, ['detach']);
  }
});

test('Rejected detach still permits the normal PIP terminal recovery without an unhandled rejection', async () => {
  const {page, events, fail} = createLifecycleBarrier();
  const pending = page.detachForBackground();
  page.bgRestorePending = true; page.background = false; page.restoreFromBackground();
  fail(new Error('PIP terminal timeout'));
  await assert.rejects(pending); await Promise.resolve();
  assert.deepEqual(events, ['restore']);
});

test('Dictation Back consumes down/up, stops its editor before removal and restores pointer focus once', () => {
  const {page} = create(); const events = [];
  Object.assign(page, { mateTvTextOpen: true, connected: true, cleanupStarted: false,
    mateTvTextController: {stopEditing() { assert.equal(page.mateTvTextOpen, true); events.push('stop-editor'); }},
    resetCanvasToDisplayDefault() {}, remoteKeyboardForeground() {return true;},
    shouldUseHardwareKeyboardProxy() { return false; },
    sessionInputOwner: {retire() {events.push('retire');}, blocked() {return false;}, debugString() {return ''; }},
    getUIContext() {return {getFocusController() {return {requestFocus(id) {
      assert.equal(page.mateTvTextOpen, false); events.push(id);
    }};}};},
    reclaimRemoteSystemPointerAfterForeground() {events.push('pointer');},
  });
  const key = type => ({keyCode:2, type, stopPropagation() {events.push('consume');}});
  assert.equal(page.mateTvTextBackKey(key(0)), true);
  assert.equal(page.mateTvTextOpen, true);
  assert.equal(page.mateTvTextBackKey(key(1)), true);
  assert.deepEqual(events, ['consume', 'consume', 'stop-editor', 'retire', 'remoteInputSurface', 'pointer']);
  page.mateTvCloseText();
  assert.equal(events.filter(e => e === 'stop-editor').length, 1);
  assert.equal(events.filter(e => e === 'pointer').length, 1);
  page.mateTvTextOpen = true; page.mateTvCloseText(false);
  assert.equal(events.filter(e => e === 'pointer').length, 1); // leave/settings do not reclaim focus
});

test('Remote gain applies only to the live session, retries unavailable audio and persists per computer', () => {
  const display = read('tv/fragments/display-members.ets');
  const source = display.slice(0, display.indexOf('  private mateTvInitStreamDefaults()'));
  const saved = new Map(), calls = [];
  let available = false, flushes = 0;
  const context = vm.createContext({
    getContext: () => ({}),
    preferences: { getPreferencesSync: () => ({
      putSync: (key, value) => saved.set(key, value), flushSync: () => flushes++
    }) }
  });
  vm.runInContext(stripTypeScriptTypes('class Gain {\n' + source.replace(/@State /g, '') +
    '\n}\nglobalThis.Gain = Gain;'), context);
  const page = new context.Gain();
  Object.assign(page, { mateTvMode: true, connected: true, cleanupStarted: false,
    sessionId: 1, hostId: 'computer-a', loader: { setRemoteAudioGain(db, id) {
      calls.push([db, id]); return available;
    } } });
  page.mateTvSetAudioGain(24, false);
  assert.equal(saved.size, 0);
  available = true;
  page.mateTvApplyAudioGain(); page.mateTvApplyAudioGain();
  assert.deepEqual(calls, [[24, 1], [24, 1]]);
  page.mateTvSetAudioGain(24, true);
  assert.equal(saved.get('mateTvAudioGainDb:computer-a'), 24);
  page.sessionId = 2; page.hostId = 'computer-b';
  page.mateTvSetAudioGain(99, true);
  assert.deepEqual(calls.at(-1), [60, 2]);
  assert.equal(saved.get('mateTvAudioGainDb:computer-b'), 60);
  assert.equal(saved.get('mateTvAudioGainDb:computer-a'), 24);
  page.mateTvSetAudioGain(NaN, true);
  assert.equal(flushes, 2);
  const count = calls.length;
  page.cleanupStarted = true; page.mateTvSetAudioGain(0, false);
  assert.equal(calls.length, count);
  page.cleanupStarted = false; page.connected = false; page.mateTvApplyAudioGain();
  assert.equal(calls.length, count);
});
