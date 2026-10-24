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
const lifecycle = read('tv/fragments/lifecycle-members.ets').split('  @Builder')[0];
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
  const context = vm.createContext({
    preferences: { getPreferencesSync() { return {
      getSync(key, fallback) { return saved.has(key) ? saved.get(key) : fallback; },
      putSync(key, value) { saved.set(key, value); }, flushSync() {},
    }; } }, getContext() {}, RUSTDESK_FPS_PREF_KEY: 'fps',
    normalizeRustDeskFps(value) { return value; },
    AppStorage: { setOrCreate(key, value) { storage.set(key, value); } },
  });
  const fragment = read('tv/fragments/display-members.ets').split('  @Builder')[0];
  vm.runInContext(stripTypeScriptTypes('class Prefs {\n' + fragment.replace(/@State /g, '') +
    '\n}\nglobalThis.Prefs = Prefs;'), context);
  const page = new context.Prefs(); page.mateTvMode = true;
  page.mateTvInitStreamDefaults();
  assert.equal(storage.get('rustdeskCodec'), 5); assert.equal(storage.get('rustdeskImageQuality'), 2);
  saved.set('rustdeskImageQuality', 1); saved.set('rustdeskCodec', 2);
  page.mateTvInitStreamDefaults();
  assert.equal(storage.get('rustdeskImageQuality'), 1); assert.equal(storage.get('rustdeskCodec'), 2);
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
  Object.assign(page, { connected: true, cleanupStarted: false, mateTvStopJoystick() {},
    mateTvCloseText() {}, mateTvCancelDrag() {}, releaseRustDeskInputBeforeBlock() {}, mateTvRefreshStreamStatus() {} });
  page.mateTvOpenDisplay(); page.mateTvOpenDisplay();
  page.mateTvCloseDisplay();
  assert.equal(page.sessionInputOwner.blocked(), false);
  // Simulate old duplicate leases, and an unrelated authentication dialog.
  page.sessionInputOwner.appeared('MateTvDisplay'); page.sessionInputOwner.appeared('MateTvDisplay');
  const auth = page.sessionInputOwner.acquire('Auth', 'system');
  page.mateTvCloseDisplay(); page.mateTvCloseDisplay();
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
