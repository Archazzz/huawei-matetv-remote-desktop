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
const fragment = read('tv/fragments/session-members.ets').split('  @Builder')[0];
const lifecycle = read('tv/fragments/lifecycle-members.ets').split('  @Builder')[0];
const transaction = session.slice(session.indexOf('  private clearPhysicalMouseClickTransaction()'),
  session.indexOf('  /**\n   * Native CONNECTED'));
function create(layout = 'macos') {
  const context = vm.createContext({
    deviceInfo: { deviceType: 'tv' },
    SourceTool: { MOUSE: 7, Finger: 1 }, SourceType: { Mouse: 2 },
    TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 },
    MouseAction: { Press: 1, Release: 2 }, MouseButton: { Left: 1 },
    hilog: { info() {}, warn() {} }, RD_DOMAIN: 0, RD_TAG: 'test',
    router: { back() { context.returns++; } }, returns: 0,
  });
  const source = policy.replace(/export /g, '') + '\nclass Harness {\n' +
    fragment.replace(/@State /g, '') + transaction + lifecycle.replace(/@State /g, '') +
    '\n}\nglobalThis.Harness = Harness;';
  vm.runInContext(stripTypeScriptTypes(source), context);
  const page = new context.Harness();
  const events = [];
  Object.assign(page, {
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
  return { page, events, touch, context };
}
test('Mac tap tolerates small sensor motion and sends exactly one click at press target', () => {
  const { page, events, touch } = create();
  touch(0); touch(2, 101, 101); touch(2, 102, 100);
  assert.deepEqual(events, []);
  touch(1, 102, 100);
  page.mateTvClick({ source: 1, x: 102, y: 100 });
  assert.deepEqual(events, [['down', 100, 100, 0], ['up', 100, 100, 0]]);
});
test('Mac held motion crosses drag threshold and releases at final target', () => {
  const { events, touch } = create();
  touch(0); touch(2, 120, 110); touch(2, 150, 130); touch(1, 160, 140);
  assert.equal(events[0][0], 'down');
  assert.deepEqual(events[0].slice(1), [100, 100, 0]);
  assert.equal(events.filter(e => e[0] === 'down').length, 1);
  assert.deepEqual(events.at(-1), ['up', 160, 140, 0]);
});
test('Windows retains immediate press and release', () => {
  const { events, touch } = create('windows');
  touch(0); assert.deepEqual(events, [['down', 100, 100, 0]]);
  touch(1); assert.equal(events.length, 2);
});
test('Cancel before a Mac drag cannot create an accidental click', () => {
  const { events, touch } = create(); touch(0); touch(3); touch(1);
  assert.deepEqual(events, []);
});
test('Cancel after a drag releases the held button even when input is blocked', () => {
  const { page, events, touch } = create(); touch(0); touch(2, 120, 110);
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
  page.mateTvCloseText = () => {}; page.mateTvCloseDisplay = () => {};
  page.disconnectAndCleanup = () => { teardowns++; page.cleanupStarted = true; };
  page.mateTvLeaveSession(); page.mateTvLeaveSession();
  assert.equal(teardowns, 1); assert.equal(context.returns, 0);
  page.mateTvFinishLeave(); page.mateTvFinishLeave();
  assert.equal(context.returns, 1);
});
