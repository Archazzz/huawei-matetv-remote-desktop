const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const source = readFileSync(require('node:path').join(__dirname,
  '../tv/overlay/entry/src/main/ets/pages/TvHome.ets'), 'utf8');

function fixture() {
  const routes = [], pending = [];
  const box = {
    HostSyncService: { getInstance: () => ({}) },
    router: { pushUrl: value => {
      routes.push(value);
      return new Promise((resolve, reject) => pending.push({ resolve, reject }));
    } },
  };
  const methods = source.slice(0, source.indexOf('  @Builder'))
    .replace(/^import[^\n]+\n/gm, '')
    .replace(/@\w+(?:\([^\n]*?\))?\s*/g, '')
    .replace('struct TvHome', 'class TvHome') + '\n}\nthis.page = new TvHome();';
  vm.createContext(box);
  vm.runInContext(stripTypeScriptTypes(methods, { mode: 'transform' }), box);
  box.page.visible = true; box.page.ready = true;
  box.page.refresh = async () => {};
  return { page: box.page, routes, pending };
}

test('header and computer navigation share one in-flight route guard', () => {
  const f = fixture();
  f.page.openPage('pages/TvInputLab');
  f.page.openPage('pages/HostListPage');
  f.page.openComputer({ id: 'computer' });
  assert.equal(f.routes.length, 1);
  assert.equal(f.routes[0].url, 'pages/TvInputLab');
  f.page.onPageHide(); f.page.onPageShow();
  f.page.openComputer({ id: 'computer' });
  assert.equal(f.routes.length, 2);
  assert.deepEqual(JSON.parse(JSON.stringify(f.routes[1])), {
    url: 'pages/RemoteDesktop', params: { hostId: 'computer' }
  });
});

test('current navigation failure is handled and allows retry', async () => {
  const f = fixture();
  f.page.openPage('pages/TvNotifications');
  f.pending[0].reject(Error('route unavailable'));
  await Promise.resolve();
  assert.equal(f.page.opening, false);
  assert.equal(f.page.error, '无法打开页面，请重试');
  f.page.openPage('pages/TvNotifications');
  assert.equal(f.routes.length, 2);
});

test('hidden page and stale rejection cannot start or unlock a newer route', async () => {
  const f = fixture();
  f.page.openPage('pages/TvNotifications');
  f.page.onPageHide();
  f.page.openPage('pages/TvInputLab');
  assert.equal(f.routes.length, 1);
  f.page.onPageShow();
  f.page.openPage('pages/HostListPage');
  f.pending[0].reject(Error('late rejection'));
  await Promise.resolve();
  assert.equal(f.page.opening, true);
  assert.equal(f.page.error, '');
  f.page.openComputer({ id: 'computer' });
  assert.equal(f.routes.length, 2);
});
