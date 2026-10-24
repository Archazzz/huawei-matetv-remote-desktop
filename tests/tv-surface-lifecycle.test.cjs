// Exercise actual pinned upstream destroy handlers with the TV claim-release hook.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync,existsSync} = require('node:fs');
const {stripTypeScriptTypes} = require('node:module');
const vm = require('node:vm');
const sessionPath = '.work/client/entry/src/main/ets/pages/RemoteDesktop.ets';
const prepared = existsSync(sessionPath);
const run = prepared ? test : (name, fn) => test(name, {skip:'Run scripts/prepare_client.py first (pinned upstream integration fixture)'}, fn);
const session = prepared ? readFileSync(sessionPath,'utf8') : '';
const fragment = readFileSync('tv/fragments/lifecycle-members.ets','utf8');
const release = fragment.slice(fragment.indexOf('  private mateTvReleasePageSurface()'),
  fragment.indexOf('  private restoreFromBackground()'));
const destroy = session.slice(session.indexOf('  private onXComponentDestroy ='),
  session.indexOf('  // ---- 输入事件转发', session.indexOf('  private onXComponentDestroy =')));
function fixture() {
  const shared = {holder:0,surface:0,destroyed:[],globalDestroys:0};
  const context = vm.createContext({hilog:{info(){},warn(){}},RD_DOMAIN:0,RD_TAG:'test',
    rdpnapi:{markXComponentSurfaceDestroyed(){shared.surface=0;shared.globalDestroys++;}}});
  vm.runInContext(stripTypeScriptTypes('class Page {\n'+release+destroy+'\n}\nglobalThis.Page=Page;'),context);
  function page(token,renderer) {
    const p = new context.Page();
    Object.assign(p,{mateTvMode:true,pictureSurfaceToken:token,pictureSurfaceMode:'process',rendererHandle:renderer,
      loader:{releaseProcessSurface(t){if(shared.holder===t)shared.holder=0;},
        markRendererSurfaceDestroyed(h){if(h>0)shared.destroyed.push(h);}},
      clearRemoteSurfaceResizeWork(){},releaseCanvasPinchInput(){},restoreRemoteSystemPointer(){}});
    return p;
  }
  return {shared,page};
}
run('Old page destroy after replacement bind cannot clear the new page process surface',()=>{
  const {shared,page}=fixture(); const old=page(1,11);shared.holder=1;shared.surface=11;
  old.mateTvReleasePageSurface();
  const next=page(2,12);shared.holder=2;shared.surface=12;
  old.onXComponentDestroy();
  assert.equal(shared.surface,12);assert.equal(shared.holder,2);
  assert.equal(shared.globalDestroys,0);assert.deepEqual(shared.destroyed,[11]);
  next.onXComponentDestroy();assert.equal(shared.surface,0);assert.equal(shared.globalDestroys,1);
});
run('Native terminal followed by delayed old callback cannot destroy the replacement frame',()=>{
  const {shared,page}=fixture();const old=page(1,-1);shared.holder=1;
  old.mateTvReleasePageSurface();shared.holder=2;shared.surface=12;
  old.onXComponentDestroy();old.onXComponentDestroy();
  assert.equal(shared.surface,12);assert.deepEqual(shared.destroyed,[]);assert.equal(shared.globalDestroys,0);
});
run('Normal current page surface destruction still stops its renderer and clears global state',()=>{
  const {shared,page}=fixture();const current=page(1,11);shared.holder=1;shared.surface=11;
  current.onXComponentDestroy();assert.equal(shared.surface,0);
  assert.deepEqual(shared.destroyed,[11]);assert.equal(shared.globalDestroys,1);
});
run('A late claim release cannot revoke a replacement page claim',()=>{
  const {shared,page}=fixture();const old=page(1,-1);shared.holder=2;shared.surface=12;
  old.mateTvReleasePageSurface();old.onXComponentDestroy();
  assert.equal(shared.holder,2);assert.equal(shared.surface,12);
});
