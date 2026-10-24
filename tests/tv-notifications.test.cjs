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
    pushService: {getToken:async()=> 'test-push-token'},
    http: { RequestMethod: {GET:'GET',POST:'POST'}, HttpDataType: {STRING:'STRING'}, createHttp: () => ({
      request: async (url,options) => { calls.push(['request',url,options]); return typeof reply === 'function' ? reply(url,options) : reply; }, destroy: () => {} }) },
    setTimeout: (f,d) => { timers.push([f,d]); return timers.length; }, clearTimeout: () => {},
    router: { back: () => calls.push(['back']) },
    hilog: {info:()=>{},warn:()=>{}}, RD_DOMAIN:0,RD_TAG:'test',
  };
  vm.createContext(box);
  vm.runInContext(compile(read(prefix+'TvPushPolicy.ets')),box);
  vm.runInContext(compile(read(prefix+'TvNotificationPolicy.ets')) + '\nthis.policy={validNotificationEvent,validNotificationBatch,resolveNotificationHost,TvNotificationRoute};',box);
  vm.runInContext(compile(read(prefix+'TvNotificationService.ets')) + '\nthis.service=TvNotificationService.getInstance();',box);
  const service=box.service;
  service.scope='scope'; service.foreground=true; service.enabled=true;
  service.config={endpoint:'https://private-host:21121',token:'private-token',publicKeyHash:'pin'};
  service.caPath='/sandbox/ca.pem'; service.store={putSync:(k,v)=>state.set(k,v),flushSync:()=>{}};
  service.context={};service.installationId='12345678-1234-1234-1234-123456789abc';
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

test('Push Kit rights error remains disabled and exposes only the numeric diagnostic',async()=>{
 const f=fixture();f.box.notificationManager.isNotificationEnabled=async()=>true;
 f.box.pushService.getToken=async()=>{throw {code:1000900012,message:'sensitive'};};
 await f.service.setBackgroundEnabled(true);
 assert.equal(f.service.isBackgroundEnabled(),false);assert.match(f.service.backgroundState(),/1000900012/);
 assert.doesNotMatch(f.service.backgroundState(),/sensitive/);assert.equal(f.calls.length,0);
});
test('background registration pins TLS and distinguishes pending cloud setup',async()=>{
 const f=fixture();f.box.notificationManager.isNotificationEnabled=async()=>true;
 f.setReply({responseCode:200,result:JSON.stringify({registered:true,cloudConfigured:false})});
 await f.service.setBackgroundEnabled(true);
 assert.equal(f.service.isBackgroundEnabled(),true);assert.match(f.service.backgroundState(),/等待中转/);
 const [_,url,o]=f.calls[0];assert.match(url,/\/v1\/push\/register$/);assert.equal(o.maxRedirects,0);
 assert.equal(o.certificatePinning.publicKeyHash,'pin');assert.equal(o.usingProxy,false);
 assert.equal(JSON.parse(o.extraData).scope,'scope');assert.equal(JSON.parse(o.extraData).previewMode,'full');
});
test('forged or disabled cloud Wants never resolve or connect',async()=>{
 const f=fixture();const nonce='N'.repeat(43);
 f.service.receiveWant({parameters:{screenLinkPushNonce:nonce,screenLinkInstallationId:f.service.installationId}});
 await Promise.resolve();assert.equal(f.calls.length,0);assert.equal(f.service.route.pendingKey,'');
 f.service.backgroundEnabled=true;
 f.service.receiveWant({parameters:{screenLinkPushNonce:nonce,screenLinkInstallationId:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}});
 await Promise.resolve();assert.equal(f.calls.length,0);
});
test('cloud click must resolve authenticated matching scope before normal host routing',async()=>{
 const f=fixture();f.service.backgroundEnabled=true;f.hosts.push(host());
 f.service.pendingPushNonce='N'.repeat(43);f.service.pendingPushInstallation=f.service.installationId;
 f.setReply({responseCode:200,result:JSON.stringify({event:event(),streamId:'stream',scope:'scope'})});
 await f.service.resolvePushClick();assert.equal(f.service.pendingHost(),'saved-host');
 assert.equal(f.service.cursor,0);assert.equal(f.service.inbox().length,1);
 assert.equal(JSON.parse(f.calls[0][2].extraData).scope,'scope');
 f.service.consume();f.service.pendingPushNonce='M'.repeat(43);f.service.pendingPushInstallation=f.service.installationId;
 f.setReply({responseCode:200,result:JSON.stringify({event:event(),streamId:'stream',scope:'other'})});
 await f.service.resolvePushClick();assert.equal(f.service.route.pendingKey,'');
});
test('disabling during in-flight resolution rejects late navigation and persists revocation',async()=>{
 const f=fixture();f.service.backgroundEnabled=true;f.hosts.push(host());
 f.service.pendingPushNonce='N'.repeat(43);f.service.pendingPushInstallation=f.service.installationId;
 let resolve;f.setReply(url=>url.endsWith('/resolve')?new Promise(r=>resolve=r):Promise.resolve({responseCode:503,result:'unavailable'}));
 const resolving=f.service.resolvePushClick();await f.service.setBackgroundEnabled(false);
 resolve({responseCode:200,result:JSON.stringify({event:event(),streamId:'stream',scope:'scope'})});await resolving;
 assert.equal(f.service.route.pendingKey,'');assert.equal(f.service.pushRevokePending,true);
 assert.equal(f.service.isBackgroundEnabled(),false);assert.equal(f.box.AppStorage.get('irrelevant'),undefined);
});
test('registration completed after disable is revoked again instead of re-enabling',async()=>{
 const f=fixture();f.box.notificationManager.isNotificationEnabled=async()=>true;let register;
 f.setReply(url=>url.endsWith('/register')?new Promise(r=>register=r):Promise.resolve({responseCode:200,result:'{"revoked":true}'}));
 const enabling=f.service.setBackgroundEnabled(true);while(!register) await Promise.resolve();
 await f.service.setBackgroundEnabled(false);register({responseCode:200,result:'{"registered":true,"cloudConfigured":true}'});await enabling;
 assert.equal(f.service.isBackgroundEnabled(),false);assert.equal(f.calls.filter(c=>c[1].endsWith('/revoke')).length,2);
});
test('lost registration response queues revocation so orphan cloud subscription is not retained',async()=>{
 const f=fixture();f.box.notificationManager.isNotificationEnabled=async()=>true;
 f.setReply({responseCode:503,result:'unavailable'});await f.service.setBackgroundEnabled(true);
 assert.equal(f.service.isBackgroundEnabled(),false);assert.equal(f.service.pushRevokePending,true);
 assert.equal(f.calls.length,2);
});
