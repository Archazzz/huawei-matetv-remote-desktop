const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {stripTypeScriptTypes} = require('node:module');
const vm = require('node:vm');
const source = readFileSync('tv/fragments/resume-members.ets', 'utf8');
const lifecycle = readFileSync('tv/fragments/lifecycle-members.ets', 'utf8').split('  @Builder')[0].replace(/@State /g, '');
function fixture() {
  let now = 0, nextTimer = 0;
  const events = [], timers = [];
  const scope = {ownerScopeId:'scope-a', generation:1};
  const context = vm.createContext({Date:{now:()=>now},
    setTimeout(fn, ms) {const id=++nextTimer;timers.push([fn,ms,id]);return id;},
    clearTimeout(id) {const i=timers.findIndex(t=>t[2]===id);if(i>=0)timers.splice(i,1);},
    hilog:{info(){},warn(){}}, RD_DOMAIN:0, RD_TAG:'test',
    AccountSessionCoordinator:{getInstance:()=>({currentScope:()=>scope})},
    router:{replaceUrl(args) {events.push(['route', args]); return Promise.resolve();}}});
  vm.runInContext(stripTypeScriptTypes('class Page {\n'+source+lifecycle+'\n}\nglobalThis.Page=Page;'),context);
  const page = new context.Page();
  const stats = {sessionActive:true,sessionId:1,receivedFrames:100,presentedFrames:100,
    rendererGeneration:2,width:1920,height:1080};
  Object.assign(page,{mateTvMode:true, sessionId:1, connectAttemptId:1,
    connected:true, backgroundDetachPromise:null,
    cleanupStarted:false,mateTvLeaving:false, background:false, pendingHost:{protocol:'rustdesk', id:'saved-host'},
    currentAbilityBackgroundState(){return this.background;},
    registryRestoreAdoptionIsCurrent(){return true;},
    clearBackgroundRenderRetry(){},clearPipRestoreRetry(){},
    performForegroundRestore(){events.push(['reattach']);},
    abandonSupersededRegistryRestore(){events.push(['abandon']);},
    disconnectAndCleanup(reason){events.push(['disconnect',reason]); this.cleanupStarted=true;},
    loader:{getConnectionState:()=>3, getRustDeskDiagnostics:()=>stats,
      requestDecoderRecovery(){events.push(['decoder']);},requestFrameRefresh(){events.push(['refresh']);}}});
  async function tick() {const [fn,ms]=timers.shift(); now+=ms; fn(); await Promise.resolve();}
  return {page,stats,events,timers,scope,tick};
}
test('Restore rejects old cumulative frames and requires fresh ingress plus presentation',async()=>{
  const f=fixture(); let done=false;
  const result=f.page.mateTvWaitForRestoredFrame(1,1,0,{...f.stats}).then(v=>{done=true;return v;});
  await f.tick(); assert.equal(done,false);
  f.stats.rendererGeneration++; // re-created renderer alone is insufficient
  await f.tick(); assert.equal(done,false);
  f.stats.receivedFrames++; await f.tick();
  assert.equal(await result,true); assert.equal(f.timers.length,0);
});

test('Actual Ability background return replaces the preserved session instead of reusing video',()=>{
  const f=fixture();f.page.background=true;f.page.mateTvObserveLifecycle(true);
  f.page.cleanupStarted=true;f.page.bgRestorePending=true;
  f.page.background=false;f.page.mateTvObserveLifecycle(false);f.page.restoreFromBackground();
  assert.deepEqual(f.events,[['disconnect','matetv-background-reconnect']]);
  assert.equal(f.timers.length,0);
  f.page.mateTvFinishResumeReconnect();assert.equal(f.events[1][0],'route');
});
test('Local panel focus and foreground-only callbacks do not force a new connection',()=>{
  const f=fixture();f.page.mateTvObserveLifecycle(false);
  assert.equal(f.page.mateTvReconnectPreservedSession(),false);
  assert.equal(f.events.length,0);
  f.page.pendingHost.protocol='rdp';f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);
  assert.equal(f.page.mateTvReconnectPreservedSession(),false);
});
test('Foreground reconnect waits for detach completion even when detach failed before setting restorePending',async()=>{
  const f=fixture();let finish;
  f.page.backgroundDetachPromise=new Promise(r=>{finish=r;});
  f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);
  f.page.restoreFromBackground();f.page.restoreFromBackground();
  assert.equal(f.events.length,0);assert.equal(f.timers.length,1);
  f.page.backgroundDetachPromise=null;finish();await Promise.resolve();
  assert.deepEqual(f.events,[['disconnect','matetv-background-reconnect']]);
  assert.equal(f.timers.length,0);
});
test('Stalled detach reports a finite failure without freeing the native session or polling again',async()=>{
  const f=fixture();f.page.backgroundDetachPromise=new Promise(()=>{});
  f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);f.page.restoreFromBackground();
  await f.tick();assert.match(f.page.connectionError,/恢复准备超时/);
  assert.equal(f.events.length,0);assert.equal(f.timers.length,0);
});
test('Re-backgrounding clears the detach deadline; another foreground arms it once',()=>{
  const f=fixture();f.page.backgroundDetachPromise=new Promise(()=>{});
  f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);f.page.restoreFromBackground();
  f.page.background=true;f.page.mateTvObserveLifecycle(true);assert.equal(f.timers.length,0);
  f.page.background=false;f.page.mateTvObserveLifecycle(false);f.page.restoreFromBackground();
  assert.equal(f.timers.length,1);f.page.mateTvCancelResumeReconnect();assert.equal(f.timers.length,0);
});
test('A preserved session superseded by another owner cannot be disconnected by foreground return',()=>{
  const f=fixture();f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);
  f.page.registryRestoreAdoptionIsCurrent=()=>false;f.page.restoreFromBackground();
  assert.deepEqual(f.events,[['abandon']]);
});
test('New packets without any new presentation cannot pass the foreground barrier',async()=>{
  const f=fixture();let done=false;
  const result=f.page.mateTvWaitForRestoredFrame(1,1,0,{...f.stats}).then(v=>{done=true;return v;});
  f.stats.receivedFrames++; await f.tick(); assert.equal(done,false);
  f.stats.presentedFrames++; await f.tick(); assert.equal(await result,true);
});
test('Silent preserved transport times out with one refresh and no decoder churn',async()=>{
  const f=fixture(); const result=f.page.mateTvWaitForRestoredFrame(1,1,0,{...f.stats});
  const rejected=assert.rejects(result,/未收到新画面/);
  while(f.timers.length) await f.tick(); await rejected;
  assert.deepEqual(f.events,[['refresh']]);
});
test('Background, owner replacement and rapid background/foreground cancel the waiter',async()=>{
  for(const change of [f=>{f.page.background=true;f.page.mateTvObserveLifecycle(true);},
    f=>{f.page.sessionId=2;}, f=>{f.page.connectAttemptId++;},
    f=>{f.page.mateTvObserveLifecycle(true);f.page.mateTvObserveLifecycle(false);}]) {
    const f=fixture(); const result=f.page.mateTvWaitForRestoredFrame(1,1,0,{...f.stats});
    change(f); await f.tick(); assert.equal(await result,false);
    assert.equal(f.timers.length,0); assert.equal(f.events.length,0);
  }
});
test('Dead native connection fails promptly without scheduling polling',async()=>{
  const f=fixture();f.page.loader.getConnectionState=()=>0;
  await assert.rejects(f.page.mateTvWaitForRestoredFrame(1,1,0,{...f.stats}),/连接已失效/);
  assert.equal(f.timers.length,0);
});
test('Failed restore disconnects once; route waits for terminal completion and uses only hostId',()=>{
  const f=fixture();
  assert.equal(f.page.mateTvReconnectAfterRestoreFailure(1,1,'test'),true);
  f.page.mateTvReconnectAfterRestoreFailure(1,1,'duplicate');
  assert.equal(f.events.length,1); assert.equal(f.events[0][0],'disconnect');
  f.page.mateTvFinishResumeReconnect(); f.page.mateTvFinishResumeReconnect();
  assert.equal(f.events.length,2);
  assert.equal(JSON.stringify(f.events[1][1]),JSON.stringify({url:'pages/RemoteDesktop',params:{hostId:'saved-host'}}));
});
test('Background, explicit leave, host change or account change cancels terminal navigation',()=>{
  for(const change of [f=>{f.page.background=true;f.page.mateTvObserveLifecycle(true);},
    f=>f.page.mateTvCancelResumeReconnect(), f=>{f.page.mateTvLeaving=true;},
    f=>{f.page.pendingHost.id='different';}, f=>{f.scope.generation++;},
    f=>{f.scope.ownerScopeId='scope-b';}]) {
    const f=fixture();f.page.mateTvReconnectAfterRestoreFailure(1,1,'test');change(f);
    f.page.mateTvFinishResumeReconnect(); assert.equal(f.events.length,1);
  }
});
test('Stale restore failure cannot disconnect a new owner or revive a background page',()=>{
  for(const change of [f=>{f.page.sessionId=2;}, f=>{f.page.background=true;},
    f=>{f.page.registryRestoreAdoptionIsCurrent=()=>false;}]) {
    const f=fixture();change(f);f.page.mateTvReconnectAfterRestoreFailure(1,1,'stale');
    assert.equal(f.events.length,0);
  }
});
test('Teardown completing in background reconnects once on the next foreground event',()=>{
 const f=fixture(); f.page.mateTvReconnectAfterRestoreFailure(1,1,'test');
 f.page.background=true;f.page.mateTvObserveLifecycle(true);
 f.page.mateTvFinishResumeReconnect(); assert.equal(f.events.length,1);
 f.page.sessionId=-1;f.page.background=false;f.page.mateTvObserveLifecycle(false);
 assert.equal(f.page.mateTvResumeReconnectOnForeground(),true);
 assert.equal(f.events.length,2);assert.equal(f.page.mateTvResumeReconnectOnForeground(),false);
});
test('Returning before teardown completes cannot route or start a duplicate teardown',()=>{
 const f=fixture(); f.page.mateTvReconnectAfterRestoreFailure(1,1,'test');
 f.page.background=true;f.page.mateTvObserveLifecycle(true);
 f.page.background=false;f.page.mateTvObserveLifecycle(false);
 assert.equal(f.page.mateTvResumeReconnectOnForeground(),true); assert.equal(f.events.length,1);
 f.page.mateTvFinishResumeReconnect(); assert.equal(f.events.length,2);
});
