const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const root = require('node:path').resolve(__dirname, '..');
const read = p => readFileSync(root + '/' + p, 'utf8');
const prefix = 'tv/overlay/entry/src/main/ets/services/notifications/';
function compile(source) {
  return stripTypeScriptTypes(source.replace(/^import[\s\S]*?;\s*/gm, '').replace(/\bexport /g, ''), { mode: 'transform' });
}
function fixture() {
  const state = new Map(), calls = [], hosts = [], timers = [];
  let reply = { responseCode: 200, result: '' };
  const box = {
    Date, Map, console, JSON,
    AppStorage: { get: k => state.get(k), setOrCreate: (k,v) => state.set(k,v) },
    AccountSessionCoordinator: { getInstance: () => ({ currentScope: () => ({ ownerScopeId: 'scope' }) }) },
    HostSyncService: { getInstance: () => ({ getAllHosts: () => hosts }) },
    TV_COMPUTER_PRESETS: [{id:'mini',address:'private-host',port:21118}],
    notificationManager: { isNotificationEnabled: async () => false },
    http: { RequestMethod: {GET:'GET'}, HttpDataType: {STRING:'STRING'}, createHttp: () => ({
      request: async (url,options) => { calls.push(['request',url,options]); return typeof reply === 'function' ? reply() : reply; }, destroy: () => {} }) },
    setTimeout: (f,d) => { timers.push([f,d]); return timers.length; }, clearTimeout: () => {},
    router: { back: () => calls.push(['back']) },
    hilog: {info:()=>{},warn:()=>{}}, RD_DOMAIN:0,RD_TAG:'test',
  };
  vm.createContext(box);
  vm.runInContext(compile(read(prefix+'TvNotificationPolicy.ets')) + '\nthis.policy={validNotificationEvent,validNotificationBatch,resolveNotificationHost,TvNotificationRoute};',box);
  vm.runInContext(compile(read(prefix+'TvNotificationService.ets')) + '\nthis.service=TvNotificationService.getInstance();',box);
  const service=box.service;
  service.scope='scope'; service.foreground=true; service.enabled=true;
  service.config={endpoint:'https://private-host:21121',token:'private-token',publicKeyHash:'pin'};
  service.caPath='/sandbox/ca.pem'; service.store={putSync:()=>{},flushSync:()=>{}};
  return {box,service,calls,hosts,timers,policy:box.policy,setReply:r=>reply=r};
}
function event(overrides={}) {
  return {cursor:1,eventId:'event-1',deviceId:'mini',deviceName:'Computer',hostId:'preset:mini',appId:'codex',appName:'Codex',title:'Done',body:'Task complete',createdAt:Date.now()-1000,expiresAt:Date.now()+60000,contentState:'complete',...overrides};
}
function host(overrides={}) {return {id:'saved-host',userId:'scope',protocol:'rustdesk',rustdeskDirectEnabled:true,rustdeskDirectHost:'private-host',rustdeskDirectPort:21118,...overrides};}
test('actual event validator rejects malformed, expired and unapproved sources',()=>{
 const {policy:p}=fixture(); const now=Date.now();assert.equal(p.validNotificationEvent(event(),now),true);
 for(const e of [null,{},event({appId:'other'}),event({body:'\0'}),event({expiresAt:now-1}),event({eventId:'../../bad'}),event({cursor:NaN}),event({contentState:'invented'})]) assert.equal(p.validNotificationEvent(e,now),false);
 assert.equal(p.validNotificationBatch({streamId:'s',events:[event({cursor:2}),event({cursor:1})],nextCursor:2,resetRequired:false}),false);
});
test('preset route resolves only one saved host in the current scope',()=>{
 const {policy:p}=fixture(),presets=[{id:'mini',address:'private-host',port:21118}];
 assert.equal(p.resolveNotificationHost('preset:mini','scope',[host()],presets),'saved-host');
 for(const hosts of [[],[host({userId:'other'})],[host(),host({id:'duplicate'})]]) assert.equal(p.resolveNotificationHost('preset:mini','scope',hosts,presets),'');
 assert.equal(p.resolveNotificationHost('https://arbitrary','scope',[host()],presets),'');
});
test('production receiver pins TLS, forbids redirects, deduplicates and never routes on arrival',async()=>{
 const f=fixture(); const e=event(); f.setReply({responseCode:200,result:JSON.stringify({streamId:'s',events:[e],nextCursor:1,resetRequired:false})});
 await f.service.poll();await f.service.poll();
 assert.equal(f.service.inbox().length,1);assert.equal(f.service.route.pendingKey,'');
 const options=f.calls[0][2];assert.equal(options.maxRedirects,0);assert.equal(options.caPath,'/sandbox/ca.pem');assert.equal(options.certificatePinning.hashAlgorithm,'SHA-256');assert.equal(options.usingProxy,false);
});
test('stream identity change resets cursor before replay and preserves event deduplication',async()=>{
 const f=fixture(),e=event();f.service.streamId='old';f.service.cursor=50;f.service.events=[e];f.service.seen=[{key:'mini/event-1',expiresAt:e.expiresAt}];
 f.setReply({responseCode:200,result:JSON.stringify({streamId:'new',events:[e],nextCursor:100,resetRequired:false})});
 await f.service.poll();assert.equal(f.service.cursor,0);assert.equal(f.service.streamId,'new');
 await f.service.poll();assert.equal(f.service.inbox().length,1);assert.equal(f.service.cursor,100);
});
test('leaving foreground discards in-flight responses and does not persist or publish them',async()=>{
 const f=fixture();let resolve;f.setReply(()=>new Promise(r=>resolve=r));const waiting=f.service.poll();
 f.service.setForeground(false);resolve({responseCode:200,result:JSON.stringify({streamId:'s',events:[event()],nextCursor:1,resetRequired:false})});await waiting;
 assert.equal(f.service.inbox().length,0);assert.equal(f.service.cursor,0);
});
test('external Want cannot supply a host; clicks require a live local event and mapping',()=>{
 const f=fixture();f.hosts.push(host());f.service.receiveWant({parameters:{hostId:'saved-host',url:'pages/RemoteDesktop'}});assert.equal(f.service.pendingHost(),'');
 f.service.receiveWant({parameters:{screenLinkNotificationEventKey:'mini/event-1'}});assert.equal(f.service.pendingHost(),'');
 f.service.events=[event()];f.service.click('mini/event-1');assert.equal(f.service.pendingHost(),'saved-host');
 f.service.events=[event({expiresAt:Date.now()-1})];assert.equal(f.service.pendingHost(),'');
});
test('real remote page handlers wait for terminal teardown before returning home',()=>{
 const f=fixture();f.hosts.push(host());f.service.events=[event()];f.service.click('mini/event-1');
 const fragment=read('tv/fragments/notification-members.ets').replace(/  @StorageLink[^\n]*\n/,'');
 const life=read('tv/fragments/lifecycle-members.ets');const methods=life.slice(life.indexOf('  private mateTvLeaveSession()'),life.indexOf('  @Builder'));
 vm.runInContext(compile('class TestRemote {\n'+fragment+methods+'\n}\nthis.remote=new TestRemote();'),f.box);
 const page=f.box.remote;Object.assign(page,{mateTvMode:true,mateTvLeaving:false,pendingHost:{id:'old-host'},hostId:'old-host',cleanupStarted:false,
  currentAbilityBackgroundState:()=>false,mateTvStopJoystick:()=>{},mateTvCancelDrag:()=>{},mateTvCloseText:()=>{},mateTvCloseDisplay:()=>{},disconnectAndCleanup:()=>f.calls.push(['disconnect'])});
 page.mateTvNotificationClick();page.mateTvNotificationClick();assert.deepEqual(f.calls,[['disconnect']]);assert.equal(f.service.route.pendingKey,'mini/event-1');
 page.mateTvFinishLeave();assert.deepEqual(f.calls,[['disconnect'],['back']]);assert.equal(f.service.pendingHost(),'saved-host');
 assert.equal(f.service.routeAction('',false,false),'open');
});
test('clicking the current host consumes the event without disconnecting',()=>{
 const f=fixture();f.hosts.push(host());f.service.events=[event()];f.service.click('mini/event-1');assert.equal(f.service.routeAction('saved-host',true,false),'same');
 f.service.consume();assert.equal(f.service.routeAction('saved-host',true,false),'none');
});
test('system clicks require an installation nonce and survive deferred cold-start validation',()=>{
 const f=fixture(), token='12345678-1234-1234-1234-123456789abc';f.hosts.push(host());f.service.events=[event()];
 f.service.receiveWant({parameters:{screenLinkNotificationClick:token}});assert.equal(f.service.pendingHost(),'');
 f.service.clicks=[{token,key:'mini/event-1',expiresAt:Date.now()+60000}];
 f.service.receiveWant({parameters:{screenLinkNotificationClick:token}});assert.equal(f.service.pendingHost(),'saved-host');
 f.service.consume();f.service.store=null;f.service.receiveWant({parameters:{screenLinkNotificationClick:token}});assert.equal(f.service.route.pendingKey,'');
 f.service.consumeWantToken();assert.equal(f.service.pendingHost(),'saved-host');
});
test('a later explicit click replaces a pending switch without parallel disconnects',()=>{
 const f=fixture();f.hosts.push(host(),host({id:'second',rustdeskDirectHost:'other'}));
 f.service.events=[event(),event({eventId:'event-2',hostId:'second'})];
 f.service.click('mini/event-1');assert.equal(f.service.routeAction('old',true,false),'leave');
 f.service.click('mini/event-2');assert.equal(f.service.routeAction('old',true,true),'wait');assert.equal(f.service.pendingHost(),'second');
});
