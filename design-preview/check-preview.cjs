/* Offline, dependency-free checks. Does not execute a shell or control a machine. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(x => x[1]);
assert.equal(scripts.length, 2);
scripts.forEach(source => new vm.Script(source));
assert(!/<script[^>]+src=|<link[^>]+href=|\bfetch\s*\(|XMLHttpRequest|WebSocket|localStorage|sessionStorage|navigator\.sendBeacon/.test(html));
const context = vm.createContext({});
vm.runInContext(scripts[0], context);
const M = context.PreviewModel;
let checks = 0;
function test(name, fn) { fn(); checks++; console.log('✓ ' + name); }
function fresh() { return M.create(); }
function act(s, ...args) { return M.action(s, ...args); }
test('Stop survives wake, login, crash and advancing sample time', () => {
 const s=fresh();act(s,'stop');for(const event of ['wake','login','crash'])act(s,event);act(s,'advance',1800);
 assert.equal(M.status(s),'Off');assert.equal(s.enabled,false);assert.equal(s.hold,false);assert.equal(s.outage,null);
});
test('Outage uses 300s delay, three 30s attempts, 30s then 60s gaps', () => {
 const s=fresh();act(s,'lost');act(s,'advance',299);assert.equal(s.outage.attempts,0);
 act(s,'advance',1);assert.equal(s.outage.phase,'active');assert.equal(s.outage.attempts,1);
 act(s,'advance',30);assert.equal(s.outage.phase,'wait');assert.equal(s.outage.nextAt,360);
 act(s,'advance',30);assert.equal(s.outage.attempts,2);act(s,'advance',30);assert.equal(s.outage.nextAt,450);
 act(s,'advance',60);assert.equal(s.outage.attempts,3);act(s,'advance',30);assert.equal(s.outage.phase,'exhausted');
 act(s,'advance',10000);assert.equal(s.outage.attempts,3);assert.equal(s.outage.promptCount,1);
});
test('Retry now consumes one remaining attempt; never overlaps or resets budget', () => {
 const s=fresh();act(s,'lost');act(s,'retry');assert.equal(s.outage.attempts,1);
 act(s,'retry');assert.equal(s.outage.attempts,1);act(s,'advance',30);act(s,'retry');assert.equal(s.outage.attempts,2);
 act(s,'advance',30);act(s,'retry');act(s,'advance',30);act(s,'retry');assert.equal(s.outage.attempts,3);
 assert.equal(s.outage.phase,'exhausted');act(s,'again');assert.equal(s.outage.attempts,1);assert.equal(s.outage.promptCount,1);
});
test('Battery closes active attempt, releases hold and preserves outage ledger', () => {
 const s=fresh();act(s,'lost');act(s,'retry');act(s,'battery');
 assert.equal(M.status(s),'Paused');assert.equal(s.hold,false);assert.equal(s.outage.phase,'suspended');assert.equal(s.outage.activeUntil,null);
 act(s,'advance',1000);assert.equal(s.outage.attempts,1);act(s,'retry');assert.equal(s.outage.attempts,1);
 act(s,'plug');act(s,'advance',500);assert.equal(s.outage.attempts,3);assert.equal(s.outage.promptCount,1);assert.equal(s.outage.phase,'exhausted');
});
test('Sleep, crash and Stop preserve attempt / prompt ledger until verified recovery', () => {
 for(const [pause,resume] of [['sleep','wake'],['crash',null],['stop','start']]){
  const s=fresh();act(s,'lost');act(s,'retry');act(s,pause);assert.equal(s.outage.attempts,1);assert.equal(s.outage.promptCount,1);
  act(s,'advance',15);if(resume)act(s,resume);act(s,'advance',1000);assert.equal(s.outage.attempts,3);assert.equal(s.outage.promptCount,1);
 }
});
test('Sleep then live settings Save cannot reopen recovery until normal wake', () => {
 const s=fresh();act(s,'lost');act(s,'sleep');act(s,'save-app',{...s.settings,outageDelay:0});act(s,'advance',1000);act(s,'retry');
 assert.equal(s.outage.attempts,0);assert.equal(s.hold,false);assert.equal(M.status(s),'Paused');
 act(s,'maintenance');assert.equal(s.hold,false);act(s,'wake');act(s,'advance',1000);assert.equal(s.outage.attempts,3);
});
test('Permission, missing package and conflicting owner prevent joins', () => {
 for(const event of ['permission','missing','conflict']){const s=fresh();act(s,'lost');act(s,event);act(s,'save-app',{...s.settings,outageDelay:0});act(s,'retry');act(s,'advance',10000);assert.equal(s.outage.attempts,0);assert.equal(M.status(s),'Error');assert.equal(s.hold,false);}
});
test('Wi-Fi association without internet does not count as recovery', () => {
 const s=fresh();act(s,'lost');act(s,'join-no-internet');act(s,'retry');act(s,'advance',30);
 assert.equal(s.lastAssociation,true);assert.equal(s.internet,false);assert.equal(M.status(s),'Recovering');assert.equal(s.outage.attempts,1);
 act(s,'broadcast');act(s,'retry');act(s,'advance',40);assert.equal(s.internet,true);assert.equal(s.outage,null);assert.equal(M.status(s),'On');
});
test('Notification denied retains one prompt and persistent guidance', () => {
 const s=fresh();act(s,'notification');act(s,'lost');act(s,'retry');assert.equal(s.outage.promptCount,1);
 assert(s.events.some(e=>e.text.includes('Persistent app + CLI guidance remains')));
});
test('App Save is live; CLI Save only changes next run', () => {
 const s=fresh();act(s,'save-cli',{...s.settings,batteryCutoff:35});assert.equal(s.settings.batteryCutoff,35);assert.equal(s.running.batteryCutoff,20);
 act(s,'save-app',{...s.settings,batteryCutoff:40});assert.equal(s.running.batteryCutoff,40);assert.equal(s.hold,true);
});
test('Matching starts attach, conflicting starts preserve the existing snapshot', () => {
 const s=fresh();act(s,'start',{display:false});assert.equal(s.running.display,true);assert.equal(s.enabled,true);
 assert(s.events[0].text.includes('Conflicting run options rejected'));act(s,'start');assert(s.events[0].text.includes('Attached'));
 act(s,'stop');act(s,'start',{display:false});assert.equal(s.running.display,false);
});
test('Login preference is respected, while manual Start remains available', () => {
 const s=fresh();act(s,'save-app',{...s.settings,login:false});act(s,'login');assert.equal(s.launched,false);assert.equal(s.enabled,true);assert.equal(s.hold,false);assert.equal(M.status(s),'Paused');
 act(s,'start');assert.equal(s.launched,true);assert.equal(s.hold,true);
});
test('Bounded crashes stop at restart budget and do not override battery', () => {
 const s=fresh();for(let i=0;i<4;i++){act(s,'crash');act(s,'advance',15);}assert.equal(M.status(s),'Error');assert.equal(s.hold,false);
 const b=fresh();act(b,'crash');act(b,'battery');act(b,'advance',15);assert.equal(b.hold,false);assert.equal(M.status(b),'Paused');
});
test('Wake cannot reacquire a hold after restart budget exhaustion', () => {
 const s=fresh();for(let i=0;i<4;i++){act(s,'crash');act(s,'advance',15);}act(s,'wake');act(s,'login');
 assert.equal(M.status(s),'Error');assert.equal(s.hold,false);assert.equal(M.canRecover(s),false);
 act(s,'start');act(s,'advance',10);assert.equal(M.status(s),'On');assert.equal(s.hold,true);
});
test('Battery observation does not suspend recovery when policy considers it safe', () => {
 for(const overrides of [{batteryProtection:false},{batteryCutoff:10}]){const s=fresh();act(s,'save-app',{...s.settings,...overrides});act(s,'lost');act(s,'retry');act(s,'battery');assert.equal(s.outage.phase,'active');assert.equal(s.hold,true);act(s,'advance',30);assert.equal(s.outage.phase,'wait');}
});
test('Disabling fallback cancels active work without granting new attempts', () => {
 const s=fresh();act(s,'lost');act(s,'retry');act(s,'save-app',{...s.settings,fallback:false});assert.equal(s.outage.phase,'disabled');assert.equal(s.outage.activeUntil,null);act(s,'advance',1000);assert.equal(s.outage.attempts,1);
 act(s,'save-app',{...s.settings,fallback:true});act(s,'advance',1000);assert.equal(s.outage.attempts,3);assert.equal(s.outage.promptCount,1);
});
test('Exhausted hotspot joins still verify returned internet without a fourth join or prompt', () => {
 const s=fresh();act(s,'lost');act(s,'advance',600);assert.equal(s.outage.phase,'exhausted');assert.equal(s.outage.attempts,3);assert.equal(s.outage.promptCount,1);
 const joinsBefore=s.events.filter(e=>e.text.includes('Join attempt ')).length, probes=s.probe.completed;
 act(s,'restore');assert.equal(s.networkReachable,true);assert.equal(s.internet,false);assert.equal(s.probe.active,true);act(s,'advance',9);assert.equal(s.internet,false);act(s,'advance',1);
 assert.equal(s.internet,true);assert.equal(s.internetFresh,true);assert.equal(s.outage,null);assert.equal(M.status(s),'On');assert.equal(s.hold,true);assert(s.probe.completed>probes);
 assert.equal(s.events.filter(e=>e.text.includes('Join attempt ')).length,joinsBefore);
});
test('Path events coalesce into one bounded probe and do not extend its deadline', () => {
 const s=fresh();act(s,'lost');const count=s.probe.started,deadline=s.probe.endsAt;act(s,'restore');act(s,'path-change');act(s,'path-change');
 assert.equal(s.probe.started,count);assert.equal(s.probe.endsAt,deadline);assert.equal(s.probe.coalesced,3);act(s,'advance',10);assert.equal(s.probe.active,false);assert.equal(s.internet,true);assert.equal(s.probe.completed,1);
});
test('Failed probes keep internet unverified and retry on a 30s eligible cadence', () => {
 const s=fresh();act(s,'lost');act(s,'advance',10);assert.equal(s.internet,false);assert.equal(s.probe.failed,1);assert.equal(s.probe.nextAt,30);
 act(s,'advance',19);assert.equal(s.probe.active,false);act(s,'advance',1);assert.equal(s.probe.active,true);assert.equal(s.probe.endsAt,40);act(s,'advance',10);assert.equal(s.probe.failed,2);
});
test('Repeated sleep / wake never probes asleep and checks fresh after each normal wake', () => {
 const s=fresh();act(s,'notification');for(let i=0;i<3;i++){act(s,'sleep');const before=s.probe.started;act(s,'restore');act(s,'maintenance');act(s,'advance',600);assert.equal(s.probe.started,before);assert.equal(s.probe.active,false);assert.equal(s.hold,false);act(s,'wake');assert.equal(s.probe.active,true);assert.equal(s.internetFresh,false);act(s,'advance',10);assert.equal(s.internet,true);assert.equal(s.internetFresh,true);assert.equal(M.status(s),'On');}
});
test('Stopped, unsafe, ownership, setup, login and crash guards prevent verification', () => {
 for(const event of ['stop','battery','permission','missing','conflict']){const s=fresh();act(s,event);const before=s.probe.started;act(s,'restore');act(s,'path-change');act(s,'advance',600);assert.equal(s.probe.started,before,event);assert.equal(s.probe.active,false,event);assert.equal(s.hold,false,event);}
 const s=fresh();act(s,'save-app',{...s.settings,login:false});act(s,'login');act(s,'restore');act(s,'advance',600);assert.equal(s.probe.started,0);
 const c=fresh();for(let i=0;i<4;i++){act(c,'crash');act(c,'advance',15);}const count=c.probe.started;act(c,'wake');act(c,'restore');act(c,'advance',600);assert.equal(c.probe.started,count);assert.equal(c.hold,false);
});
test('Stop and battery cancel active verification immediately', () => {
 for(const event of ['stop','battery']){const s=fresh();act(s,'lost');assert.equal(s.probe.active,true);act(s,event);assert.equal(s.probe.active,false);assert.equal(s.probe.cancelled,1);assert.equal(s.probe.endsAt,null);}
});
test('Connectivity-only pause recovers awake, inactivity release waits for normal wake', () => {
 const s=fresh();act(s,'connectivity-pause');assert.equal(s.hold,false);act(s,'restore');act(s,'advance',10);assert.equal(s.hold,true);assert.equal(s.connectivityPaused,false);
 act(s,'idle-release');const count=s.probe.started;act(s,'restore');act(s,'advance',100);assert.equal(s.hold,false);assert.equal(s.probe.started,count);act(s,'plug');assert.equal(s.hold,false);act(s,'wake');act(s,'advance',10);assert.equal(s.hold,true);
});
// Minimal DOM adapter checks generated flows and command dispatch, not browser layout.
const elements = new Map();
function element(id='') { return {id,innerHTML:'',textContent:'',value:'',children:[],dataset:{},classList:{add(){},remove(){},toggle(){}},focus(){document.activeElement=this;},addEventListener(){},append(x){this.children.push(x)},querySelector(){return element()},querySelectorAll(){return []},closest(){return null},scrollIntoView(){}}; }
const eventHandlers={};
const document = {activeElement:element(),getElementById(id){if(!elements.has(id))elements.set(id,element(id));return elements.get(id)},querySelectorAll(){return []},querySelector(){return null},createElement(){return element()},addEventListener(type,handler){eventHandlers[type]=handler;}};
const uiContext = vm.createContext({document,window:{scrollTo(){}},setTimeout(){return 1},clearTimeout(){},console});
scripts.forEach(source=>vm.runInContext(source,uiContext));
const P=uiContext.NightrPreview;
const mainKeydown=eventHandlers.keydown;
function get(){return P.getState();}
function ui(){return P.getUI();}
function useTestNetwork(){let used=P.networkUse();if(!used&&P.networkSecurity()==='unknown'){P.networkSecuritySelect('open');used=P.networkUse();}if(!used&&P.networkSecurity()==='secured')used=P.demoPasswordSubmit('preview-only');return used;}

test('Status JSON and config --show are read-only and never open a picker', () => {
 P.reset();const before=JSON.stringify(get());P.runCommand('nightr status --json');assert.equal(JSON.stringify(get()),before);assert.equal(ui().cliScreen,null);assert.equal(JSON.parse(ui().cliEntries.at(-1).out).sample,true);
 P.runCommand('nosleep config --show');assert.equal(ui().cliScreen,null);assert.equal(JSON.stringify(get()),before);assert(JSON.parse(ui().cliEntries.at(-1).out).next_run);
});
test('Legacy mode flags and aliases produce run-only snapshots', () => {
 P.reset();P.runCommand('nightr stop');P.runCommand('nosleep --display=dim --lock off --checks agent --require 1 --hotspot off --background');
 const s=get();assert.equal(s.running.displayMode,'dim');assert.equal(s.running.lock,false);assert.equal(s.running.checks,'agent');assert.equal(s.running.require,'1');assert.equal(s.running.fallback,false);assert.equal(s.settings.displayMode,'on');
 P.runCommand('nightr stop');P.runCommand('nightr start -d off -l on --no-internet --background');assert.equal(get().running.display,false);assert.equal(get().running.lock,true);assert.equal(get().running.checks,'agent');
});
test('Invalid sample flags do not mutate monitor state', () => {
 P.reset();const before=JSON.stringify(get());P.runCommand('nightr --display banana');assert.equal(JSON.stringify(get()),before);assert(ui().cliEntries.at(-1).out.includes('No state changed'));
});
test('Full parent menu preserves order and every sibling offers staged navigation', () => {
 P.reset();P.runCommand('t config');const text=elements.get('content').innerHTML;
 const names=['Default tool','Automatic folder trust','Claude settings','Codex settings','Local worker &amp; models','Workflows','Test runners','Sessions server','Repositories','Worktrees &amp; branches','Hosts','Default beam host','Nightr','Open config in editor','Cancel','SAVE CHANGES'];
 let at=-1;for(const name of names){const next=text.indexOf(name,at+1);assert(next>at,name);at=next;}
 for(let i=0;i<12;i++){P.railAction('parent:'+i);assert.equal(ui().cliScreen,'sibling');P.railAction('field:0');assert.equal(ui().cliScreen,'field');P.railAction('choice:0');assert.equal(ui().cliScreen,'sibling');P.railAction('sibling-back');assert.equal(ui().cliScreen,'parent');assert.equal(ui().cliFocus,i);}
});
test('Pending sibling edits gate Nightr; review save opens Nightr and returns focus', () => {
 P.reset();P.runCommand('t config');P.railAction('parent:0');P.railAction('field:0');P.railAction('choice:1');P.railAction('sibling-back');P.railAction('parent:12');assert.equal(ui().cliScreen,'gate');
 P.railAction('gate-back');assert.equal(ui().cliFocus,12);P.railAction('parent:12');P.railAction('gate-save');assert.equal(ui().cliScreen,'review');P.railAction('review-save');assert.equal(ui().cliScreen,'nightr');
 P.railAction('nightr-cancel');assert.equal(ui().cliScreen,'parent');assert.equal(ui().cliFocus,12);assert.equal(ui().parentSaved['Default tool'].value,'claude');
});
test('Parent discard preserves saved siblings and gates external editor', () => {
 P.reset();P.runCommand('t config');P.railAction('parent:0');P.railAction('field:0');P.railAction('choice:1');P.railAction('sibling-back');P.railAction('parent:13');assert.equal(ui().cliScreen,'gate');assert.equal(ui().gateTarget,'editor');
 P.railAction('gate-back');P.railAction('parent:12');P.railAction('gate-discard');assert.equal(ui().parentDraft['Default tool'].value,'codex');assert.equal(ui().cliScreen,'nightr');
});
test('CLI config is keyboard rail-based and saves next-run changes', () => {
 P.reset();P.runCommand('nightr config');assert.equal(ui().cliScreen,'nightr');assert(!elements.get('content').innerHTML.includes('data-setting="cli:'));
 P.railAction('nightr-field:0');assert.equal(ui().cliScreen,'nightr-field');P.railAction('nightr-choice:2');assert.equal(ui().cliDraft.displayMode,'dim');P.railAction('nightr-review');P.railAction('nightr-save');assert.equal(get().settings.displayMode,'dim');assert.equal(get().running.displayMode,'on');
});
test('Settings tabs preserve all staged values, Save applies live and Cancel restores saved state', () => {
 P.reset();P.appSettingsOpen();P.appSettingsEdit('login',false);P.appSettingsTab('connectivity');P.appSettingsEdit('outageDelay',120);P.appSettingsTab('general');assert.equal(ui().settingsDraft.login,false);P.appSettingsTab('advanced');P.appSettingsEdit('backoff',45);P.appSettingsSave();assert.equal(get().running.outageDelay,120);assert.equal(get().settings.login,false);assert.equal(get().settings.backoff,45);
 P.appSettingsOpen();P.appSettingsEdit('login',true);P.appSettingsTab('protection');P.appSettingsEdit('displayMode','dim');P.appSettingsCancel();assert.equal(get().settings.login,false);assert.equal(get().running.displayMode,'on');assert.equal(ui().settingsDraft,null);
});
test('Locked moon icon, full grouped settings, prominent Nightr tab and download contract render', () => {
 P.reset();P.setView('icons');const markup=elements.get('content').innerHTML;assert(markup.includes('Moon + spark is locked'));assert(!markup.includes('data-icon='));assert(!html.includes("eye:{"));assert(!html.includes("line:{"));assert(!html.includes('Choose an icon'));
 const seen=new Set();P.setView('app');P.appSettingsOpen();for(const tab of ['general','protection','connectivity','advanced']){P.appSettingsTab(tab);const settings=elements.get('content').innerHTML;for(const match of settings.matchAll(/data-setting="app:([^"]+)"/g))seen.add(match[1]);}assert.equal(seen.size,16);assert.equal(seen.has('require'),false);assert.equal(seen.has('inactivity'),false);assert.equal(typeof ui().settingsDraft.require,'string');P.appSettingsCancel();
 P.setView('website');assert(elements.get('content').innerHTML.includes('Download for macOS'));assert(!html.includes('Apple command-line tools for local builds'));assert(!html.includes('Build for macOS'));assert(!html.includes('./scripts/build-app.sh'));assert(html.includes('No Xcode or separate Python installation'));assert(html.includes('Simulate DMG download'));assert(html.includes('Simulate drag to Applications'));assert(html.includes('Simulate authorized setup'));
 P.setView('hangar');assert(elements.get('content').innerHTML.includes('new-badge'));assert(elements.get('content').innerHTML.includes('data-product="nightr"'));
});
test('Protection groups preserve inactive values and never disable battery policy', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('protection');let markup=elements.get('content').innerHTML;
 for(const heading of ['Keep Mac awake','When lid closes','On battery'])assert(markup.includes('<legend>'+heading+'</legend>'));
 assert(markup.includes('Automatically'));assert(markup.includes('Until I stop'));assert(!markup.includes('<h3>Protection</h3>'));assert(!markup.includes('Passing checks required'));assert(markup.includes('Both must apply.'));
 P.appSettingsEdit('require','2');P.appSettingsEdit('forever',true);assert.equal(P.settingDisabled('checks'),true);assert.equal(P.settingDisabled('require'),true);assert.equal(P.settingDisabled('batteryProtection'),false);assert.equal(ui().settingsDraft.require,'2');assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.require,'2');assert.equal(get().settings.forever,true);
 P.appSettingsOpen();P.appSettingsEdit('batteryProtection',false);assert.equal(P.settingDisabled('batteryCutoff'),true);assert.equal(ui().settingsDraft.batteryCutoff,20);P.appSettingsEdit('batteryProtection',true);assert.equal(P.settingDisabled('batteryCutoff'),false);P.appSettingsCancel();
});
test('Advanced exact-input and slider events sync without rendering or focus loss', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');const exact=document.getElementById('timing-value-every'),range=document.getElementById('timing-range-every');exact.dataset={setting:'app:every',timingExact:'every'};exact.type='number';range.dataset={timingRange:'every'};range.type='range';
 const previousQuery=document.querySelectorAll;document.querySelectorAll=selector=>selector==='[data-timing-exact]'?[exact]:selector==='[data-timing-range]'?[range]:selector==='[data-setting]'?[exact]:[];P.render();const before=elements.get('content').innerHTML;
 exact.focus();exact.value='1200';exact.oninput();assert.equal(ui().settingsDraft.every,1200);assert.equal(range.value,'300');assert(elements.get('timing-range-note-every').textContent.includes('Outside slider range'));assert.equal(document.activeElement,exact);assert.equal(elements.get('content').innerHTML,before);
 range.focus();range.value='111';range.oninput();assert.equal(ui().settingsDraft.every,111);assert.equal(exact.value,'111');assert.equal(elements.get('timing-range-note-every').textContent,'');assert.equal(document.activeElement,range);assert.equal(elements.get('content').innerHTML,before);document.querySelectorAll=previousQuery;P.appSettingsCancel();
});
test('Advanced values outside convenient windows survive browsing and save without clamping', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');P.timingInput('every','3600');P.timingInput('grace','86400');P.appSettingsTab('general');P.appSettingsTab('advanced');const markup=elements.get('content').innerHTML;assert(markup.includes('value="3600"'));assert(markup.includes('value="86400"'));assert.equal((markup.match(/Outside slider range · exact value retained/g)||[]).length,2);
 assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.every,3600);assert.equal(get().settings.grace,86400);
 P.runCommand('nightr config');assert.equal(ui().cliDraft.every,3600);assert.equal(ui().cliDraft.grace,86400);P.railAction('nightr-cancel');
});
test('Numeric settings reject fractions, empty and invalid values with field errors', () => {
 for(const bad of ['','2.5','-1','3601']){P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');P.timingInput('every',bad);assert.equal(P.appSettingsSave(),false,bad);assert.equal(get().settings.every,30);assert(ui().settingsErrors.every.includes('whole number'));assert.equal(ui().settingsTab,'advanced');assert.equal(ui().settings,true);P.appSettingsCancel();}
 P.reset();P.appSettingsOpen();P.timingInput('grace','0');P.timingInput('retries','0');assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.grace,0);assert.equal(get().settings.retries,0);
});
test('Connectivity shows sample facts and distinct safe macOS guidance', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');const markup=elements.get('content').innerHTML;for(const title of ['<legend>Connection</legend>','<legend>Hotspot fallback</legend>','<legend>macOS settings</legend>','Auto-join iPhone hotspot'])assert(markup.includes(title));assert.equal((markup.match(/class="macos-guidance-row"/g)||[]).length,1);assert(markup.includes('viewBox="0 0 24 24"'));assert(markup.includes('aria-label="Advanced settings"'));assert(markup.includes('M3 6h4m4 0h10'));assert(markup.includes('aria-labelledby="settings-tab-connectivity"'));assert(markup.includes('data-connectivity-guide="auto"'));assert(markup.includes('3 total attempts. Internet checks keep running.'));assert(!markup.includes('connection-facts'));assert(!markup.includes('<h3>Connectivity</h3>'));assert(markup.includes('aria-label="Auto-join iPhone hotspot: Not checked. Open setup guidance."'));assert(html.includes("wifi:['Connect your hotspot'"));assert(!html.includes('This is an optional desktop notification simulation.'));
 P.appSettingsEdit('fallback',false);assert.equal(P.settingDisabled('ssid'),true);assert.equal(P.settingDisabled('outageDelay'),true);assert.equal(ui().settingsDraft.ssid,'Sample iPhone');
 const before=JSON.stringify(get()),trigger=element('instant-guide');trigger.focus();P.connectivityGuidance('instant');let dialog=elements.get('modal-root').innerHTML;assert(dialog.includes('Use your nearby iPhone when Wi-Fi is unavailable.'));assert(dialog.includes('Current: Not checked'));assert(dialog.includes('Ask to join hotspots'));assert.equal((dialog.match(/<p[ >]/g)||[]).length,3);elements.get('modal-root').children=[element()];eventHandlers.keydown({key:'Escape',preventDefault(){},target:element()});elements.get('modal-root').children=[];assert.equal(ui().settings,true);assert.equal(document.activeElement,trigger);
 assert.equal(JSON.stringify(get()),before);P.appSettingsCancel();
});
test('Settings hash links select a focused section without editing or saving values', () => {
 for(const tab of ['protection','connectivity','advanced']){P.reset();const before=JSON.stringify(get());assert.equal(P.settingsHash('#settings/'+tab),true);assert.equal(ui().settings,true);assert.equal(ui().settingsTab,tab);assert.equal(JSON.stringify(get()),before);assert.equal(P.settingsHash('#settings/'+tab+'?every=1'),false);assert.equal(ui().settingsDraft.every,30);P.appSettingsCancel();}
 for(const tab of ['protection','connectivity','advanced']){const startup=vm.createContext({document,window:{location:{hash:'#settings/'+tab,search:'?every=1'},scrollTo(){},addEventListener(){}},setTimeout(){return 1},clearTimeout(){},console});scripts.forEach(source=>vm.runInContext(source,startup));const initialized=startup.NightrPreview.getUI();assert.equal(initialized.settings,true);assert.equal(initialized.settingsTab,tab);assert.equal(initialized.settingsDraft.every,30);assert.equal(startup.NightrPreview.getState().settings.every,30);}
});
test('App checkboxes map every selection to all-selected policy on intentional edits', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('protection');P.appCheckToggle('agent',false);assert.equal(ui().settingsDraft.checks,'internet');assert.equal(ui().settingsDraft.require,'all');P.appCheckToggle('internet',false);assert.equal(ui().settingsDraft.checks,'');assert.equal(ui().settingsErrors.checks,'Select one, or choose Until I stop.');assert.equal(P.appSettingsSave(),false);P.appCheckToggle('agent',true);assert.equal(ui().settingsDraft.checks,'agent');P.appCheckToggle('internet',true);assert.equal(ui().settingsDraft.checks,'agent,internet');assert.equal(ui().settingsDraft.require,'all');assert.equal(P.appSettingsSave(),true);
});
test('Imported CLI policy survives unrelated Save and changes only after a checkbox edit', () => {
 for(const requirement of ['1','2','none']){P.reset();P.act('save-cli',{...get().settings,require:requirement});P.appSettingsOpen();P.appSettingsTab('protection');assert(elements.get('content').innerHTML.includes('Custom CLI policy retained'));assert(!elements.get('content').innerHTML.includes('Both must apply.'));P.appSettingsTab('general');P.appSettingsEdit('login',false);P.appSettingsTab('advanced');P.appSettingsTab('protection');assert.equal(ui().settingsDraft.require,requirement);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.require,requirement);
 P.appSettingsOpen();P.appCheckToggle('internet',false);assert.equal(ui().settingsDraft.checks,'agent');assert.equal(ui().settingsDraft.require,'all');assert.equal(elements.get('settings-custom-policy').textContent,'');assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.require,'all');}
});
test('Legacy empty checks stay untouched on unrelated Save, newly empty choices require Until stopped', () => {
 P.reset();P.act('save-cli',{...get().settings,checks:'',require:'none'});P.appSettingsOpen();P.appSettingsEdit('notifications',false);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.checks,'');assert.equal(get().settings.require,'none');
 P.appSettingsOpen();P.appCheckToggle('agent',true);P.appCheckToggle('agent',false);assert.equal(P.appSettingsSave(),false);assert.equal(ui().settingsErrors.checks,'Select one, or choose Until I stop.');P.appSettingsEdit('forever',true);assert.equal(ui().settingsErrors.checks,undefined);P.appSettingsEdit('forever',false);assert.equal(ui().settingsErrors.checks,'Select one, or choose Until I stop.');P.appSettingsEdit('forever',true);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.checks,'');assert.equal(get().settings.forever,true);
});
test('Until stopped dims checks without dropping selection and restores them when off', () => {
 P.reset();P.appSettingsOpen();P.appCheckToggle('internet',false);P.appSettingsEdit('forever',true);P.appSettingsTab('protection');let markup=elements.get('content').innerHTML;assert(markup.includes('data-app-check="agent"'));assert.equal(P.settingDisabled('checks'),true);assert.equal(ui().settingsDraft.checks,'agent');assert.equal(P.settingDisabled('batteryProtection'),false);P.appSettingsTab('advanced');P.appSettingsTab('protection');P.appSettingsEdit('forever',false);assert.equal(P.settingDisabled('checks'),false);assert.equal(ui().settingsDraft.checks,'agent');P.appSettingsCancel();assert.equal(get().settings.checks,'agent,internet');
 P.reset();P.act('save-cli',{...get().settings,require:'none'});P.appSettingsOpen();assert.equal(P.settingDisabled('checks'),false);P.appSettingsCancel();
});
test('Battery protection has concise action, percent cutoff and preserves inactive value', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('protection');let markup=elements.get('content').innerHTML;assert(markup.includes('Allow sleep below'));assert(markup.includes('<span>Lock Mac</span>'));assert(!markup.includes('<span>1</span>'));assert(markup.includes('class="battery-inline"'));assert(markup.includes('aria-label="Battery cutoff percent"'));assert(markup.includes('<span aria-hidden="true">%</span>'));assert(markup.includes('Plug in or recharge to resume.'));assert(!markup.includes('Pauses protection and recovery.'));
 P.appSettingsTab('general');assert(elements.get('content').innerHTML.includes('<span>Desktop notification prompt</span>'));assert(!elements.get('content').innerHTML.includes('<span>1</span>'));P.appSettingsTab('protection');P.appSettingsEdit('batteryCutoff',27);P.appSettingsEdit('batteryProtection',false);P.appSettingsTab('general');P.appSettingsTab('protection');assert.equal(P.settingDisabled('batteryCutoff'),true);assert.equal(ui().settingsDraft.batteryCutoff,27);P.appSettingsEdit('batteryProtection',true);assert.equal(ui().settingsDraft.batteryCutoff,27);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.batteryCutoff,27);
});
test('Simple awake mode uses one native radio group and preserves focus and draft policy', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('protection');let markup=elements.get('content').innerHTML;assert.equal((markup.match(/name="nightr-awake-mode"/g)||[]).length,2);assert.equal((markup.match(/type="radio"/g)||[]).length,2);assert(!markup.includes('Keep awake until I stop it'));assert(!markup.includes('All selected checks'));assert(!markup.includes('safe power'));assert(markup.includes('Agent is active'));assert(markup.includes('Internet is available'));
 const radio=document.getElementById('awake-mode-until');radio.dataset={setting:'app:forever',awakeMode:'until'};radio.type='radio';radio.value='until';radio.checked=true;
 const previous=document.querySelectorAll;document.querySelectorAll=selector=>selector==='[data-setting]'?[radio]:[];P.render();const before=elements.get('content').innerHTML;radio.focus();radio.onchange();assert.equal(ui().settingsDraft.forever,true);assert.equal(ui().settingsDraft.checks,'agent,internet');assert.equal(document.getElementById('automatic-conditions').hidden,true);assert.equal(document.activeElement,radio);assert.equal(elements.get('content').innerHTML,before);document.querySelectorAll=previous;
 P.appModeSelect('automatic');assert.equal(ui().settingsDraft.forever,false);assert.equal(document.getElementById('automatic-conditions').hidden,false);P.appSettingsCancel();
});
test('Hidden conditions and custom CLI policy survive mode switches and unrelated Save', () => {
 P.reset();P.act('save-cli',{...get().settings,checks:'agent',require:'1'});P.appSettingsOpen();P.appSettingsTab('protection');P.appModeSelect('until');P.appSettingsTab('advanced');P.appSettingsTab('protection');let markup=elements.get('content').innerHTML;assert(markup.includes('id="automatic-conditions" hidden'));assert.equal(ui().settingsDraft.checks,'agent');assert.equal(ui().settingsDraft.require,'1');P.appModeSelect('automatic');assert.equal(ui().settingsDraft.checks,'agent');assert.equal(ui().settingsDraft.require,'1');P.appSettingsEdit('notifications',false);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.require,'1');
 P.appSettingsOpen();P.appCheckToggle('internet',true);assert.equal(ui().settingsDraft.require,'all');assert.equal(document.getElementById('settings-custom-policy').textContent,'Both must apply.');P.appCheckToggle('agent',false);assert.equal(document.getElementById('settings-custom-policy').textContent,'');P.appSettingsCancel();
});
test('Connection strip distinguishes verified, probing, stale and association-only states', () => {
 P.reset();const s=get(),before=JSON.stringify(s);assert.equal(P.connectivitySummary(s).label,'Connected');assert.equal(JSON.stringify(s),before);
 s.probe.active=true;assert.equal(P.connectivitySummary(s).label,'Checking internet…');s.probe.active=false;s.internetFresh=false;assert.equal(P.connectivitySummary(s).label,'Awaiting verification');s.internet=false;s.lastAssociation=true;assert.equal(P.connectivitySummary(s).label,'No internet');
 s.outage={phase:'active',attempts:2,limit:3};assert.equal(P.connectivitySummary(s).detail,'Hotspot attempt 2 of 3');s.outage.phase='exhausted';s.outage.attempts=3;assert.equal(P.connectivitySummary(s).detail,'3 attempts used · still checking internet');
});
test('Connection strip never claims active checks while stopped, asleep, unsafe or disabled', () => {
 P.reset();const base=get();base.internet=false;base.outage={phase:'exhausted',attempts:3,limit:3};
 for(const change of [{enabled:false},{asleep:true,releaseUntilWake:true},{ac:false,battery:12},{permission:false},{running:{...base.running,checks:'agent'}}]){const s={...base,...change},summary=P.connectivitySummary(s);assert(!summary.detail.includes('still checking internet'));assert(!['Connected','Checking internet…'].includes(summary.label));}
});
test('Hotspot form keeps exact seconds and disabled staged values with native info controls', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');P.appSettingsEdit('ssid','Sample Phone');P.appSettingsEdit('outageDelay',179);P.appSettingsEdit('fallback',false);P.appSettingsTab('general');P.appSettingsTab('connectivity');const markup=elements.get('content').innerHTML;
 assert(markup.includes('Use saved hotspot'));assert(markup.includes('for="setting-app-ssid">Hotspot'));assert(markup.includes('for="setting-app-outageDelay">Try after'));assert(markup.includes('value="179"'));assert(markup.includes('<span>seconds</span>'));assert(markup.includes('value="Sample Phone"'));assert.equal(P.settingDisabled('ssid'),true);assert.equal(P.settingDisabled('outageDelay'),true);
 assert.equal((markup.match(/class="macos-guidance-row"/g)||[]).length,1);assert(!markup.includes('>Guide…</button>'));assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.outageDelay,179);assert.equal(get().settings.ssid,'Sample Phone');
});
test('Advanced groups explain the timing sequence without an undefined inactivity control', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');const markup=elements.get('content').innerHTML;
 for(const label of ['Automatic checks','Before allowing sleep'])assert(markup.includes('<legend>'+label+'</legend>'));
 for(const label of ['Check every','Wait before retrying','Extra attempts','First retry delay'])assert(markup.includes(label));
 for(const help of ['How often to check the conditions selected in Protection.','Keep awake through pauses or lost internet before retrying.','Retry failed conditions before allowing sleep.','Later waits double, up to 5 minutes.','These limits apply when the lid is closed.'])assert(markup.includes(help));
 assert(!markup.includes('<h3>Advanced</h3>'));assert(!markup.includes('timing-value-inactivity'));assert(!markup.includes('Health-check retries are separate from the three hotspot'));
 assert.equal((markup.match(/<span class="timing-unit">seconds<\/span>/g)||[]).length,3);assert(markup.includes('15 minutes'));P.appSettingsCancel();
});
test('Zero extra attempts disables first delay while preserving its exact value', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');P.timingInput('backoff','47');P.timingInput('retries','0');assert.equal(P.settingDisabled('backoff'),true);assert.equal(ui().settingsDraft.backoff,47);assert.equal(document.getElementById('timing-help-retries').textContent,'No extra attempts');assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.backoff,47);
 P.appSettingsOpen();P.appSettingsTab('advanced');let markup=elements.get('content').innerHTML;assert(markup.includes('No extra attempts'));P.timingInput('retries','2');assert.equal(P.settingDisabled('backoff'),false);assert.equal(ui().settingsDraft.backoff,47);assert.equal(document.getElementById('timing-help-retries').textContent,'Retry failed conditions before allowing sleep.');P.appSettingsCancel();
});
test('Duration hints are exact and leave stored seconds untouched', () => {
 assert.equal(P.durationHint(900),'15 minutes');assert.equal(P.durationHint(901),'15 minutes 1 second');assert.equal(P.durationHint(3600),'1 hour');assert.equal(P.durationHint(86400),'24 hours');assert.equal(P.durationHint(30),'');assert.equal(P.durationHint(60.5),'');
 P.reset();P.appSettingsOpen();P.appSettingsTab('advanced');P.timingInput('grace','901');assert.equal(ui().settingsDraft.grace,901);assert.equal(document.getElementById('timing-duration-grace').textContent,'15 minutes 1 second');P.appSettingsTab('general');P.appSettingsTab('advanced');assert.equal(ui().settingsDraft.grace,901);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.grace,901);
});
test('Hidden inactivity value survives app edits and remains available in CLI compatibility', () => {
 P.reset();P.act('save-cli',{...get().settings,inactivity:37});P.appSettingsOpen();P.appSettingsTab('advanced');assert(!elements.get('content').innerHTML.includes('data-setting="app:inactivity"'));P.timingInput('every','44');assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.inactivity,37);
 P.runCommand('nightr config');assert.equal(ui().cliDraft.inactivity,37);assert(elements.get('content').innerHTML.includes('Agent inactivity window'));P.railAction('nightr-cancel');
});
test('SSID validation matches exact UTF-8 limits without trimming or normalization', () => {
 for(const name of ['a','a'.repeat(32),'é'.repeat(16),'😀'.repeat(8),' '.repeat(32),' café ','A\u2028B','\uFEFF'])assert.equal(P.validateSSID(name).valid,true,JSON.stringify(name));
 for(const name of ['', 'a'.repeat(33),'é'.repeat(17),'😀'.repeat(9),'bad\0name','a\n','\u0085','\u007f','\ud800','\udc00','\ud800x'])assert.equal(P.validateSSID(name).valid,false,JSON.stringify(name));
 assert.equal(P.validateSSID('😀').bytes,4);assert.equal(P.validateSSID('é').bytes,2);assert.equal(P.validateSSID(' ').bytes,1);
});
test('Nearby networks deduplicate exact names and rank current before signal strength', () => {
 const rows=P.normalizeWifi([{ssid:'current',rssi:-90},{ssid:'net',rssi:-60},{ssid:'net',rssi:-20},{ssid:'Net',rssi:-30},{ssid:' net ',rssi:-40},{ssid:'<Guest & Friends>',rssi:-50},{ssid:'bad\0name',rssi:-10}],'current');
 assert.equal(rows[0].ssid,'current');assert.equal(rows[1].ssid,'net');assert.equal(rows[1].rssi,-20);assert.equal(rows.length,5);assert(rows.some(r=>r.ssid==='Net'));assert(rows.some(r=>r.ssid===' net '));assert.equal(P.wifiFixture('complete').rows.length,4);
});
test('Configured absence is reported only from fresh complete discovery', () => {
 for(const state of ['scanning','permission','denied','off','unavailable','stale','error'])assert.equal(P.wifiAvailability(P.wifiFixture(state),'Absent phone'),'Availability unknown',state);
 assert.equal(P.wifiAvailability(P.wifiFixture('complete'),'Absent phone'),'Not seen');assert.equal(P.wifiAvailability(P.wifiFixture('empty'),'Absent phone'),'Not seen');
 P.reset();P.appSettingsOpen();P.appSettingsEdit('ssid','Absent phone');P.networkChooserOpen();assert(P.savedWifiOptions().some(row=>row.ssid==='Absent phone'&&row.meta==='Configured · Not seen'));P.networkChooserClose();P.appSettingsCancel();
});
test('Network choice is local until Use, then parent-staged until Save', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');P.appSettingsEdit('notifications',false);const modelBefore=JSON.stringify(get());P.networkChooserOpen();P.networkSelect('Travel Hotspot');P.networkTab('nearby');P.networkTab('manual');assert.equal(ui().networkChooser.selected,'Travel Hotspot');assert.equal(ui().settingsDraft.ssid,'Sample iPhone');P.networkChooserClose();assert.equal(ui().settingsDraft.ssid,'Sample iPhone');assert.equal(ui().settingsDraft.notifications,false);
 P.networkChooserOpen();P.networkTab('manual');P.networkSelect(' exact phone ');const token=P.networkScanStart();assert.equal(P.networkScanComplete(token),true);assert.equal(ui().networkChooser.selected,' exact phone ');assert.equal(useTestNetwork(),true);assert.equal(ui().settingsDraft.ssid,' exact phone ');assert.equal(JSON.stringify(get()),modelBefore);P.appSettingsCancel();assert.equal(get().settings.ssid,'Sample iPhone');
 P.appSettingsOpen();P.networkChooserOpen();P.networkSelect('Travel Hotspot');useTestNetwork();assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.ssid,'Travel Hotspot');
});
test('Saved and manual choices remain usable in every discovery failure state', () => {
 for(const state of ['empty','permission','denied','off','unavailable','stale','error','scanning']){P.reset();P.setWifiScenario(state);P.appSettingsOpen();P.networkChooserOpen();assert(P.savedWifiOptions().some(row=>row.ssid==='Sample iPhone'));P.networkTab('manual');P.networkSelect('Manual '+state);assert.equal(useTestNetwork(),true,state);assert.equal(ui().settingsDraft.ssid,'Manual '+state);P.appSettingsCancel();}
 P.setWifiScenario('complete');
});
test('Scan generations reject late results after refresh, cancel and reopen', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkSelect('Travel Hotspot');const first=P.networkScanStart(),second=P.networkScanStart();assert.equal(P.networkScanComplete(first,'empty'),false);assert.equal(P.networkScanComplete(second,'complete'),true);assert.equal(ui().networkChooser.selected,'Travel Hotspot');
 const cancelled=P.networkScanStart();P.networkChooserClose();P.networkChooserOpen();assert.equal(P.networkScanComplete(cancelled,'empty'),false);assert.equal(ui().networkChooser.scan.state,'ok');P.networkChooserClose();P.appSettingsCancel();
});
test('Manual exact names escape markup and parent validation accepts spaces but rejects invalid names', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');const name='<img src=x> & "phone"';P.networkSelect(name);P.networkTab('saved');P.networkTab('manual');const dialog=elements.get('modal-root').innerHTML;assert(!dialog.includes('<img src=x>'));assert(dialog.includes('&lt;img src=x&gt;'));assert.equal(useTestNetwork(),true);assert.equal(ui().settingsDraft.ssid,name);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.ssid,name);
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('   ');assert.equal(useTestNetwork(),true);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.ssid,'   ');
 for(const name of ['a'.repeat(33),'bad\0name','\ud800']){P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect(name);assert.equal(P.networkUse(),false);P.networkChooserClose();P.appSettingsEdit('ssid',name);assert.equal(P.appSettingsSave(),false);P.appSettingsCancel();}
});
test('Chooser tabs and Escape retain the parent draft and return to the invoking button', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');const trigger=element('choose-hotspot');trigger.isConnected=true;trigger.focus();P.networkChooserOpen();const before=ui().settingsDraft.ssid;
 mainKeydown({key:'ArrowRight',target:{dataset:{networkTab:'saved'}},preventDefault(){}});assert.equal(ui().networkChooser.tab,'nearby');P.networkSelect('Travel Hotspot');mainKeydown({key:'Escape',target:element(),preventDefault(){}});assert.equal(ui().networkChooser,null);assert.equal(ui().settingsDraft.ssid,before);assert.equal(ui().settings,true);assert.equal(document.activeElement,trigger);P.appSettingsCancel();
});
test('Discovery actions and outer fixtures stay out of the product configuration', () => {
 P.reset();P.setWifiScenario('complete');P.appSettingsOpen();P.appSettingsTab('connectivity');assert(elements.get('content').innerHTML.includes('readonly data-setting="app:ssid"'));assert(elements.get('content').innerHTML.includes('data-wifi-scenario'));P.networkChooserOpen();P.networkTab('nearby');let dialog=elements.get('modal-root').innerHTML;assert(dialog.includes('Refresh'));assert(!dialog.includes('Enable discovery'));assert(!dialog.includes('data-wifi-scenario'));
 P.networkChooserClose();P.setWifiScenario('permission');P.networkChooserOpen();P.networkTab('nearby');dialog=elements.get('modal-root').innerHTML;assert(dialog.includes('Enable discovery'));assert.equal((dialog.match(/Permission needed/g)||[]).length,1);const token=P.networkScanStart(true);assert.equal(P.networkScanComplete(token),true);assert.equal(ui().networkChooser.scan.state,'ok');P.networkChooserClose();P.appSettingsCancel();P.setWifiScenario('complete');
});
test('Manually saved secured networks prompt for a demo password and never retain its raw value', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Travel Hotspot');assert.equal(P.networkUse(),false);assert.equal(ui().networkChooser.step,'select');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));const markup=elements.get('network-credential-host').innerHTML;assert(markup.includes('type="password"'));assert(!/id="network-demo-password"[^>]*value=/.test(markup));
 const secret='DO-NOT-PERSIST-SECRET-123',input=document.getElementById('network-demo-password');input.value=secret;assert.equal(P.demoPasswordSubmit(),true);assert.equal(input.value,'');assert.equal(P.credentialStatus('Travel Hotspot'),'Pending save');assert(!JSON.stringify(ui()).includes(secret));assert(!JSON.stringify(get()).includes(secret));assert(!elements.get('content').innerHTML.includes(secret));
 assert.equal(P.appSettingsSave(),true);assert.equal(P.credentialStatus('Travel Hotspot'),'Password saved');assert.equal(P.credentialSecurity('Travel Hotspot'),'secured');assert(!JSON.stringify(ui()).includes(secret));
});
test('Manual security is explicit and open networks never request a password', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Open sample');assert.equal(P.networkUse(),false);assert.equal(P.networkSecurity(),'secured');P.networkSecuritySelect('open');assert.equal(P.networkUse(),true);assert.equal(P.appSettingsSave(),true);assert.equal(P.credentialSecurity('Open sample'),'open');assert.equal(P.credentialStatus('Open sample'),'Open network');
 P.appSettingsOpen();P.networkChooserOpen();P.networkSelect('Studio Wi-Fi');assert.equal(P.networkUse(),true);P.appSettingsCancel();
});
test('Credential cancellation and atomic save failure preserve config and previous credentials', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Travel Hotspot');P.networkUse();P.demoPasswordSubmit('demo-password');P.appSettingsCancel();assert.equal(ui().credentialSaved['Travel Hotspot'],undefined);assert.equal(get().settings.ssid,'Sample iPhone');
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Travel Hotspot');P.networkUse();P.demoPasswordSubmit('demo-password');const before=JSON.stringify(get()),saved=JSON.stringify(ui().credentialSaved),security=JSON.stringify(ui().securitySaved);P.setCredentialSaveFailure(true);const retry=element('retry-save'),query=document.querySelector;document.querySelector=selector=>selector==='[data-settings-save]'?retry:query(selector);assert.equal(P.appSettingsSave(),false);assert.equal(document.activeElement,retry);document.querySelector=query;assert.equal(JSON.stringify(get()),before);assert.equal(JSON.stringify(ui().credentialSaved),saved);assert.equal(JSON.stringify(ui().securitySaved),security);assert(ui().pendingCredentials['Travel Hotspot']);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.ssid,'Travel Hotspot');assert.equal(ui().credentialSaved['Travel Hotspot'],true);
});
test('Exact SSID prototype names are ordinary credential keys through save and reset', () => {
 for(const name of ['__proto__','constructor','toString']){P.reset();assert.equal(P.credentialStatus(name),'Security unknown');P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect(name);P.networkSecuritySelect('secured');assert.equal(P.networkUse(),false);assert.equal(ui().networkChooser.step,'select');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));P.demoPasswordSubmit('demo-password');assert.equal(P.appSettingsSave(),true);assert.equal(Object.hasOwn(ui().credentialSaved,name),true);assert.equal(ui().credentialSaved[name],true);assert.equal(P.credentialSecurity(name),'secured');assert.equal(get().settings.ssid,name);P.reset();assert.equal(P.credentialStatus(name),'Security unknown');assert.equal(Object.hasOwn(ui().credentialSaved,name),false);}
});
test('Changing security replaces mismatched pending metadata and persists exact classification', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Transition');P.networkSecuritySelect('secured');P.networkUse();P.demoPasswordSubmit('demo-password');assert.equal(ui().pendingCredentials.Transition.security,'secured');
 P.networkChooserOpen();P.networkTab('manual');P.networkSecuritySelect('open');assert.equal(P.networkUse(),true);assert.equal(ui().pendingCredentials.Transition,undefined);assert.equal(P.appSettingsSave(),true);assert.equal(P.credentialSecurity('Transition'),'open');assert.equal(ui().credentialSaved.Transition,undefined);
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSecuritySelect('secured');assert.equal(P.networkUse(),false);assert.equal(ui().networkChooser.step,'select');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));P.demoPasswordSubmit('new-demo-pass');assert.equal(P.appSettingsSave(),true);assert.equal(P.credentialStatus('Transition'),'Password saved');
});
test('Late scan completion cannot clear a password field; cancellation does clear it', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');const token=P.networkScanStart();P.networkSelect('Travel Hotspot');P.networkUse();const input=document.getElementById('network-demo-password');input.value='transient-demo';assert.equal(P.networkScanComplete(token),true);assert.equal(ui().networkChooser.step,'select');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));assert.equal(input.value,'transient-demo');P.networkChooserClose();assert.equal(input.value,'');assert(!JSON.stringify(ui()).includes('transient-demo'));P.appSettingsCancel();
});
test('Attempt limits 1, 3 and 10 are captured and exhaustion never starts an extra join', () => {
 for(const limit of [1,3,10]){const s=fresh();act(s,'save-app',{...s.settings,hotspotAttempts:limit});act(s,'lost');assert.equal(s.outage.limit,limit);act(s,'advance',10000);assert.equal(s.outage.attempts,limit);assert.equal(s.outage.phase,'exhausted');assert.equal(s.outage.promptCount,1);act(s,'advance',10000);assert.equal(s.outage.attempts,limit);assert.equal(M.snapshot(s).recovery.maxAttempts,limit);}
 assert.deepEqual([1,2,3,4,5,6].map(M.joinGap),[30,60,120,240,300,300]);
});
test('App limit changes apply next cycle; CLI defaults wait for a new run', () => {
 const s=fresh();act(s,'lost');act(s,'retry');act(s,'save-app',{...s.settings,hotspotAttempts:5});assert.equal(s.outage.limit,3);act(s,'advance',1000);assert.equal(s.outage.attempts,3);act(s,'again');assert.equal(s.outage.limit,5);assert.equal(s.outage.attempts,1);
 const c=fresh();act(c,'lost');act(c,'save-cli',{...c.settings,hotspotAttempts:1});act(c,'advance',1000);act(c,'again');assert.equal(c.outage.limit,3);act(c,'stop');act(c,'restore');act(c,'start');act(c,'advance',10);act(c,'lost');assert.equal(c.outage.limit,1);
});
test('Attempt limit and consumed budget survive battery sleep and crash pauses', () => {
 for(const event of ['battery','sleep','crash']){const s=fresh();act(s,'save-app',{...s.settings,hotspotAttempts:10});act(s,'lost');act(s,'retry');act(s,event);assert.equal(s.outage.limit,10);assert.equal(s.outage.attempts,1);assert.equal(s.outage.activeUntil,null);if(event==='battery')act(s,'plug');if(event==='sleep')act(s,'wake');if(event==='crash')act(s,'advance',15);assert.equal(s.outage.limit,10);assert.equal(s.outage.attempts,1);}
});
test('Invalid hotspot attempt limits cannot save and do not change the active budget', () => {
 for(const limit of [0,11,1.5,'',NaN]){P.reset();P.appSettingsOpen();P.appSettingsEdit('hotspotAttempts',limit);assert.equal(P.appSettingsSave(),false);assert.equal(get().settings.hotspotAttempts,3);P.appSettingsCancel();}
});
test('macOS sample profiles distinguish Automatic Ask-only and unknown auto-join', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');for(const [profile,label]of [['unknown','Unknown'],['setup','Setup needed'],['eligible','Automatic'],['ask','Ask'],['earlier','Ask']]){P.setMacProfile(profile);const markup=elements.get('content').innerHTML;assert(markup.includes(label));assert.equal((markup.match(/class="macos-guidance-row"/g)||[]).length,1);assert(!markup.includes('Details…'));assert(!markup.includes('Setup…'));}
 assert.equal(P.credentialStatus('Sample iPhone'),'Password saved');assert.equal(P.credentialSecurity('Studio Wi-Fi'),'open');assert.equal(get().settings.ssid,'Sample iPhone');
});
test('Saved list selections use Keychain metadata without password controls', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');assert(!elements.get('content').innerHTML.includes('data-change-password'));P.networkChooserOpen();for(const tab of ['saved']){P.networkTab(tab);for(const name of ['Sample iPhone','Travel Hotspot','Studio Wi-Fi','Café Pocket']){P.networkSelect(name);const inline=elements.get('network-credential-host').innerHTML;assert(!inline.includes('type="password"'));assert(!inline.includes('data-network-security'));assert(!inline.includes('<button'));}const token=P.networkScanStart();P.networkScanComplete(token);assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));}P.networkChooserClose();P.appSettingsCancel();
});
test('Manually saved existing password reuses on blank input and replaces in the same field', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');assert(elements.get('network-credential-host').innerHTML.includes('Leave blank to use saved password.'));assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);P.networkChooserOpen();P.networkTab('manual');const input=document.getElementById('network-demo-password');input.value='replacement-demo-only';assert.equal(P.networkUse(),true);assert.equal(input.value,'');assert.equal(ui().pendingCredentials['Sample iPhone'].validated,true);assert(!JSON.stringify(ui()).includes('replacement-demo-only'));assert.equal(P.appSettingsSave(),true);
});
test('Tab changes clear the DOM password before showing target credential controls', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('Travel Hotspot');const input=document.getElementById('network-demo-password');input.value='transient-manual-only';P.networkTab('nearby');assert.equal(input.value,'');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));const token=P.networkScanStart();P.networkScanComplete(token);assert.equal(input.value,'');P.networkTab('saved');assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));P.networkTab('manual');assert.equal(input.value,'');P.networkChooserClose();P.appSettingsCancel();
});
test('Manual unknown security cannot commit and secured choice reveals inline field immediately', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSelect('New manual hotspot');assert.equal(P.networkSecurity(),'secured');assert.equal(P.networkUse(),false);assert.equal(ui().networkChooser.error,'Enter a demo password.');P.networkSecuritySelect('secured');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));assert.equal(ui().networkChooser.step,'select');P.networkSecuritySelect('open');assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));assert.equal(P.networkUse(),true);P.appSettingsCancel();
});
test('macOS guidance rows use readonly readiness marks without Sample or Details actions', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');let markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert.equal((markup.match(/class="macos-guidance-row"/g)||[]).length,1);assert.equal((markup.match(/data-readiness="unknown"/g)||[]).length,1);assert(!markup.includes('Sample'));assert(!markup.includes('Details'));assert(!markup.includes('Setup…'));assert(!markup.includes('type="checkbox"'));
 P.setMacProfile('eligible');markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert.equal((markup.match(/data-readiness="on"/g)||[]).length,1);assert(markup.includes('Auto-join iPhone hotspot: Automatic'));
 P.setMacProfile('earlier');markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert(markup.includes('Auto-join iPhone hotspot: Ask'));assert(markup.includes('Open setup guidance.'));P.appSettingsCancel();
});
test('Manual defaults to password entry and keeps its selected security while names change', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');assert.equal(P.networkSecurity(),'secured');P.networkSelect('First manual name');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));const input=document.getElementById('network-demo-password');input.value='temporary-demo';P.networkSelect('Second manual name');assert.equal(input.value,'');assert.equal(P.networkSecurity(),'secured');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));
 P.networkSecuritySelect('open');P.networkSelect('Third manual name');assert.equal(P.networkSecurity(),'open');assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));P.networkChooserClose();
 P.networkChooserOpen();P.networkSelect('Café Pocket');assert.equal(P.networkSecurity(),'unknown');assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);P.appSettingsCancel();
});
test('Missing or unknown list credentials are never auto-saved and stale Manual security cannot clear Keychain', () => {
 for(const tab of ['saved']){P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab(tab);P.networkSelect('Travel Hotspot');assert(elements.get('network-credential-host').innerHTML.includes('Password needed in macOS Wi-Fi.'));assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);assert.equal(P.appSettingsSave(),true);assert.equal(ui().credentialSaved['Travel Hotspot'],undefined);assert.equal(P.credentialStatus('Travel Hotspot'),'Password needed');}
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('manual');P.networkSecuritySelect('open');P.networkTab('saved');assert.equal(P.networkSecurity(),'secured');assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);assert.equal(P.appSettingsSave(),true);assert.equal(ui().credentialSaved['Sample iPhone'],true);
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('saved');P.networkSelect('Café Pocket');assert.equal(P.networkUse(),true);assert.equal(P.appSettingsSave(),true);assert.equal(P.credentialSecurity('Café Pocket'),'unknown');assert.equal(ui().credentialSaved['Café Pocket'],undefined);
});
test('macOS on off and unknown marks use high-contrast 20px SVG boxes and guides omit product labels', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');for(const [profile,state,count]of [['unknown','unknown',1],['setup','off',1],['eligible','on',1]]){P.setMacProfile(profile);const markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert.equal((markup.match(new RegExp('data-readiness="'+state+'"','g'))||[]).length,count);assert.equal((markup.match(/<rect x="2" y="2" width="16" height="16"/g)||[]).length,1);assert.equal((markup.match(/width="20" height="20"/g)||[]).length,1);assert(!markup.includes('type="checkbox"'));}P.connectivityGuidance('instant');assert(!elements.get('modal-root').innerHTML.includes('Sample guidance'));assert(!elements.get('modal-root').innerHTML.includes('Details'));uiContext.closeModal();P.appSettingsCancel();
});
test('Settings appearance follows the selected light and dark theme', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');P.setAppearance('light');assert(elements.get('content').innerHTML.includes('native-settings native-light'));assert(html.includes('.native-settings.native-light{--native-bg:#f6f5f2f2;--native-ink:#202228;'));assert(html.includes('.native-settings.native-light button{background:#ffffff;color:#202228;'));assert(html.includes('.native-settings.native-light button:disabled{background:#ececea;color:#85878d;'));P.setAppearance('dark');assert(!elements.get('content').innerHTML.includes('native-settings native-light'));P.appSettingsCancel();
});
test('Nearby requests missing secured passwords but saved and open networks need no input', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Sample iPhone');assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));P.networkSelect('Studio Wi-Fi');assert(!elements.get('network-credential-host').innerHTML.includes('type="password"'));P.networkSelect('Travel Hotspot');assert(elements.get('network-credential-host').innerHTML.includes('type="password"'));assert.equal(P.networkUse(),false);assert.equal(ui().networkChooser.error,'Enter a demo password.');const input=document.getElementById('network-demo-password');input.value='nearby-demo-password';assert.equal(P.networkUse(),true);assert.equal(input.value,'');assert.equal(ui().pendingCredentials['Travel Hotspot'].validated,true);assert(!JSON.stringify(ui()).includes('nearby-demo-password'));P.appSettingsCancel();assert.equal(ui().credentialSaved['Travel Hotspot'],undefined);
});
test('Nearby unknown security is exact-SSID scoped and never inherits Manual choices', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Café Pocket');assert.equal(P.networkSecurity(),'unknown');assert.equal(P.networkUse(),false);P.networkSecuritySelect('open');assert.equal(P.networkSecurity(),'open');P.networkSelect('Café Pocket ');assert.equal(P.networkSecurity(),'unknown');P.networkSelect('Travel Hotspot');assert.equal(P.networkSecurity(),'secured');P.networkTab('manual');P.networkSecuritySelect('open');P.networkTab('nearby');assert.equal(P.networkSecurity(),'secured');
 P.networkSelect('__proto__');P.networkSecuritySelect('secured');assert.equal(Object.hasOwn(ui().networkChooser.nearbySecurity,'__proto__'),true);assert.equal(P.networkSecurity(),'secured');P.networkSelect('constructor');assert.equal(P.networkSecurity(),'unknown');P.networkChooserClose();P.appSettingsCancel();
});
test('Nearby refresh preserves same-identity input but tabs name and security transitions clear it', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Travel Hotspot');const input=document.getElementById('network-demo-password');input.value='nearby-transient-only';const token=P.networkScanStart();assert.equal(input.value,'nearby-transient-only');P.networkScanComplete(token);assert.equal(input.value,'nearby-transient-only');assert(!JSON.stringify(ui()).includes('nearby-transient-only'));P.networkTab('manual');assert.equal(input.value,'');input.value='manual-transient';P.networkTab('nearby');assert.equal(input.value,'');input.value='new-secret';P.networkSelect('Café Pocket');assert.equal(input.value,'');P.networkSecuritySelect('secured');input.value='choice-secret';P.networkSecuritySelect('open');assert.equal(input.value,'');P.networkChooserClose();P.appSettingsCancel();
});
test('Nearby pending credentials preserve atomic parent Cancel failure and retry behavior', () => {
 P.reset();P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Travel Hotspot');P.demoPasswordSubmit('nearby-demo-pass');P.appSettingsCancel();assert.equal(ui().credentialSaved['Travel Hotspot'],undefined);
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Travel Hotspot');P.demoPasswordSubmit('nearby-demo-pass');const before=JSON.stringify(get());P.setCredentialSaveFailure(true);assert.equal(P.appSettingsSave(),false);assert.equal(JSON.stringify(get()),before);assert.equal(ui().credentialSaved['Travel Hotspot'],undefined);assert.equal(P.appSettingsSave(),true);assert.equal(get().settings.ssid,'Travel Hotspot');assert.equal(ui().credentialSaved['Travel Hotspot'],true);
});
test('Nearby Open never authorizes deleting an existing Keychain entry', () => {
 P.reset();vm.runInContext("U.credentialSaved['Studio Wi-Fi']=true;U.securitySaved['Studio Wi-Fi']='open';U.credentialSaved['Café Pocket']=true;U.securitySaved['Café Pocket']='unknown';",uiContext);P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Studio Wi-Fi');assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);assert.equal(P.appSettingsSave(),true);assert.equal(ui().credentialSaved['Studio Wi-Fi'],true);
 P.appSettingsOpen();P.networkChooserOpen();P.networkTab('nearby');P.networkSelect('Café Pocket');P.networkSecuritySelect('open');assert.equal(P.networkUse(),true);assert.equal(Object.keys(ui().pendingCredentials).length,0);assert.equal(P.appSettingsSave(),true);assert.equal(ui().credentialSaved['Café Pocket'],true);
});
test('macOS section retains only compact Auto-join guidance', () => {
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');for(const [profile,status]of [['unknown','Not checked'],['eligible','Automatic'],['ask','Ask'],['earlier','Ask'],['unavailable','Unavailable']]){P.setMacProfile(profile);const markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert.equal((markup.match(/class="macos-guidance-row"/g)||[]).length,1);assert(markup.includes('Auto-join iPhone hotspot: '+status));assert(!markup.includes('Wake'));}P.appSettingsCancel();
});
test('Auto-join marks follow the setting independently of Instant Hotspot eligibility', () => {
 for(const [instant,autoJoin,label,ready,unknown]of [['Ready','Ask','Ask',false,false],['Unknown','Automatic','Automatic',true,false],['Ready','Unknown','Not checked',false,true],['Ready','Ask only','Ask',false,false],['Ready','Unavailable','Unavailable',false,false]]){const value=P.autoJoinStatus({instant,autoJoin});assert.equal(value.label,label);assert.equal(value.ready,ready);assert.equal(value.unknown,unknown);}
 P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');P.setMacProfile('ask');const markup=elements.get('content').innerHTML.split('<legend>macOS settings</legend>')[1].split('</fieldset>')[0];assert(markup.includes('Status only · change in System Settings.'));assert(markup.split('data-connectivity-guide="auto"')[1].split('</button>')[0].includes('data-readiness="off"'));assert(!markup.includes('Instant Hotspot'));P.appSettingsCancel();
});
test('Auto-join dialogs explain current setting purpose and actionable path without changing settings', () => {
 P.reset();P.appSettingsOpen();const before=JSON.stringify(get());for(const [profile,status,instruction]of [['unknown','Not checked','Choose Automatic on macOS 26+.'],['ask','Ask','Choose Automatic on macOS 26+.'],['eligible','Automatic','Choose Automatic on macOS 26+.'],['earlier','Ask','Automatic needs macOS 26+; use Ask to Join here.']]){P.setMacProfile(profile);P.connectivityGuidance('auto');const markup=elements.get('modal-root').innerHTML;for(const copy of ['Auto-join iPhone hotspot','Current: '+status,'Use your nearby iPhone when Wi-Fi is unavailable.','System Settings → Wi-Fi → Ask to join hotspots',instruction])assert(markup.includes(copy));uiContext.closeModal();}assert.equal(JSON.stringify(get()),before);P.appSettingsCancel();
});
test('Removed network-wake guides and fixtures cannot open dialogs', () => {
 P.reset();P.appSettingsOpen();const before=JSON.stringify(get());for(const kind of ['wake','wake-ac','wake-battery']){assert.equal(P.connectivityGuidance(kind),false);assert.equal(elements.get('modal-root').innerHTML,'');}assert.equal(JSON.stringify(get()),before);for(const token of ['wakeAC','wakeBattery','Wake for network access','Wake on both sources','data-connectivity-guide="wake'])assert(!html.includes(token));P.appSettingsCancel();
});
test('Settings scrolls only its content and macOS read disclosure stays outside product controls', () => {
 assert(html.includes('.native-settings{display:flex;flex-direction:column;overflow:hidden}'));assert(html.includes('.native-settings-header,.native-settings-footer{position:static;flex:0 0 auto}'));assert(html.includes('.native-settings-content{flex:1 1 auto;min-height:0;overflow-y:auto;overscroll-behavior:contain}'));assert.equal((html.match(/Preview does not read macOS settings\./g)||[]).length,1);P.reset();P.appSettingsOpen();P.appSettingsTab('connectivity');assert(!elements.get('content').innerHTML.split('class="native-settings-content"')[1].split('</footer>')[0].includes('Preview does not read macOS settings.'));P.appSettingsCancel();
});
test('Every surface renders offline and preserves selected icon family', () => {
 for(const view of ['app','icons','website','hangar','guide']){P.setView(view);assert(elements.get('content').innerHTML.length>1000);}
 assert(html.includes('Build with agents.<br>On your own hardware.'));
 assert(html.includes('viewBox="0 0 28 28"'));
});
console.log(`\n${checks} preview checks passed. Inline syntax and offline constraints passed.`);
