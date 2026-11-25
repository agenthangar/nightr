// Run with Playwright's managed Chromium headless shell. All fixtures are local.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

async function run() {
  const files = new Map([
    ['index.html', 'text/html'], ['activity.html', 'text/html'], ['nightr-app-icon.png', 'image/png']
  ]);
  const server = http.createServer(async (req, res) => {
    const file = new URL(req.url, 'http://localhost').pathname.slice(1);
    if (!files.has(file)) return res.writeHead(404).end();
    try {
      res.writeHead(200, { 'Content-Type': files.get(file) });
      res.end(await fs.readFile(path.join(__dirname, file)));
    } catch { res.destroy(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  let browser;
  try {
    browser = await chromium.launch({headless:true, executablePath: process.env.PLAYWRIGHT_HEADLESS_SHELL});
    const page = await browser.newPage({ viewport: { width: 1100, height: 850 } });
    const failures = [];
    page.on('pageerror', error => failures.push(error.message));
    const capture = async (locator, name) => {
      if (process.env.NIGHTR_PREVIEW_CAPTURES) {
        await locator.screenshot({path:path.join(process.env.NIGHTR_PREVIEW_CAPTURES, name + '.png')});
      }
    };
    await page.goto(base + '/index.html#settings/connectivity');
    for (const theme of ['light','dark']) {
      await page.evaluate(t => NightrPreview.setAppearance(t), theme);
      await page.evaluate(() => NightrPreview.setMacProfile('eligible'));
      for (const tab of ['general','protection','advanced','connectivity']) {
        await page.locator('[data-settings-tab="'+tab+'"]').click();
        const pane = page.locator('.native-settings');
        const form = pane.locator('.native-settings-content');
        const geometry = await form.evaluate(el => [el.scrollHeight, el.clientHeight]);
        assert(geometry[0] <= geometry[1]+1, tab+' overflows at the default size: '+geometry);
        await capture(pane, tab+'-'+theme);
        if (tab==='advanced'||tab==='connectivity') {
          const field=pane.locator('.ds-count input');
          const arrows=pane.locator('.ds-stepper');
          const fieldBox=await field.boundingBox(), arrowsBox=await arrows.boundingBox();
          assert.equal(arrowsBox.x-(fieldBox.x+fieldBox.width),6);
          if(!(await field.isDisabled())){
            const initial=Number(await field.inputValue());
            await arrows.getByRole('button',{name:/Increase/}).click();
            assert.equal(Number(await field.inputValue()),initial+1);
            await arrows.getByRole('button',{name:/Decrease/}).click();
            assert.equal(Number(await field.inputValue()),initial);
          }
        }
        if (tab==='protection') {
          const forceControl=pane.getByRole('group',{name:'Force mode',exact:true}).getByRole('checkbox');
          assert(await pane.getByRole('group',{name:'Keep Mac awake',exact:true}).getByLabel('When a local model is generating',{exact:true}).isVisible());
          assert(!(await forceControl.isChecked()));
          const rule=pane.getByLabel('When an agent is active');
          const initialRule=await rule.boundingBox();
          const forceBox=await forceControl.boundingBox();
          assert.equal(forceBox.x+forceBox.width,initialRule.x+initialRule.width);
          await forceControl.check();
          assert.deepEqual(await rule.boundingBox(),initialRule);
          assert(await pane.getByText('Automatic checks are paused.',{exact:true}).first().isVisible());
          assert.equal(await pane.locator('#awake-mode').count(),0);
          for(const option of await pane.getByRole('group',{name:'Keep Mac awake'}).getByRole('checkbox').all()) assert(await option.isDisabled());
          assert(await pane.getByLabel('Lock Mac').isEnabled());
          const fits = await form.evaluate(el => el.scrollHeight <= el.clientHeight+1);
          assert(fits,'Force mode clips Protection in '+theme);
          await capture(pane,'protection-force-'+theme);
          assert(await forceControl.isChecked());
          await forceControl.click();
          assert.equal(await page.evaluate(() => NightrPreview.getState().force),false);
          assert(!(await forceControl.isChecked()));
          for(const option of await pane.getByRole('group',{name:'Keep Mac awake'}).getByRole('checkbox').all()) assert(await option.isEnabled());
        }
      }
      for (const [profile, expected, confirmed] of [['eligible','Automatic',true],['ask','Ask to Join',false],['unknown','Unknown',false]]) {
        await page.evaluate(p => NightrPreview.setMacProfile(p),profile);
        const status = page.locator('[data-hotspot-mode] .ds-status');
        assert((await status.textContent()).includes(expected));
        assert.equal(await status.locator('.ds-check').count(),Number(confirmed));
        if (confirmed) {
          const ink = el => getComputedStyle(el).color;
          const textColor = await status.evaluate(ink);
          assert.equal(textColor,await status.locator('.ds-check').evaluate(ink));
          const [r,g,b] = textColor.match(/\d+/g).map(Number);
          assert(g>r && g>b,theme+' status must be green');
        }
        await page.getByRole('button',{name:'Open Wi-Fi Settings'}).focus();
        assert(await page.getByRole('button',{name:'Open Wi-Fi Settings'}).evaluate(b => b===document.activeElement));
      }
      await page.locator('[data-choose-network]').click();
      const sheet = page.locator('.modal:has(.network-chooser)');
      let anchors;
      for (const tab of ['saved','nearby','manual']) {
        await sheet.locator('[data-network-tab="'+tab+'"]').click();
        const heading = await sheet.locator('.chooser-heading').boundingBox();
        const footer = await sheet.getByRole('button',{name:'Use network'}).boundingBox();
        const current = [heading.x,heading.y,footer.x,footer.y];
        if (anchors) current.forEach((v,i) => assert(Math.abs(v-anchors[i])<=1,'Chooser alignment: '+tab));
        anchors=current;
        if (tab==='nearby') {
          await sheet.locator('[data-network-value="Travel Hotspot"]').check();
          const password=sheet.getByLabel('Password',{exact:true});
          await password.click();
          await password.pressSequentially('synthetic-only');
          assert(await sheet.getByRole('button',{name:'Use network'}).isEnabled());
          await sheet.locator('[data-network-value="Sample iPhone"]').check();
          assert.equal(await password.count(),0);
          await sheet.getByRole('button',{name:'Change password'}).click();
          assert.equal(await password.inputValue(),'');
          assert(await sheet.getByRole('button',{name:'Use network'}).isDisabled());
          await password.pressSequentially('synthetic-replacement');
          assert(await sheet.getByRole('button',{name:'Use network'}).isEnabled());
        }
        if (tab==='manual') {
          await sheet.getByLabel('Network name').fill('Fixture guest');
          const password=sheet.getByLabel('Password',{exact:true});
          assert(await password.isVisible());
          const commit=sheet.getByRole('button',{name:'Use network'});
          assert(await commit.isDisabled());
          await password.fill('synthetic-only');
          assert(await commit.isEnabled());
          const initialPassword = await password.elementHandle();
          await sheet.getByLabel('Network name').press('End');
          await sheet.getByLabel('Network name').pressSequentially('123');
          assert(await password.evaluate((field, original) => field === original, initialPassword));
          assert.equal(await password.inputValue(),'');
          assert(await commit.isDisabled());
          await sheet.getByLabel('Network security').selectOption('open');
          assert.equal(await password.count(),0);
        }
        await capture(sheet,'chooser-'+tab+'-'+theme);
      }
      await page.keyboard.press('Escape');
      assert(!(await sheet.isVisible()));
    }
    await page.goto(base + '/activity.html');
    const anchors=()=>page.locator('.native-brand,.status-title,.pane-actions button,.models-heading').evaluateAll(nodes=>nodes.map(el=>{
      const {x,y,width,height}=el.getBoundingClientRect();
      return [x,y,el.matches('.status-title')?0:width,height];
    }));
    const initial=await anchors();
    for(const action of ['#force-mode','#force-mode','#primary','#primary']){
      await page.locator(action).click();
      assert.deepEqual(await anchors(),initial);
      const forced=(await page.locator('#force-mode').textContent())==='End force mode';
      const paused=page.locator('.native-status .item').filter({hasText:'Checks paused'});
      assert.equal(await paused.count(),forced?1:0);
      assert.equal(await page.locator('[data-agent-row]').count(),forced?0:1);
      if(forced) assert.equal(await paused.locator('.status-good').count(),0);
    }
    const boundary = await page.locator('.local-models').evaluate(section => {
      const style = getComputedStyle(section);
      const actions = document.querySelector('.pane-actions').getBoundingClientRect();
      return { border: style.borderTopStyle, width: parseFloat(style.borderTopWidth),
               above: section.getBoundingClientRect().top - actions.bottom,
               below: parseFloat(style.paddingTop) };
    });
    assert.equal(boundary.border, 'solid');
    assert(boundary.width > 0 && boundary.above >= 20 && boundary.below >= 20);
    await page.locator('[data-model-key]').first().click();
    const details = page.locator('#model-info');
    assert(await details.isVisible());
    await capture(details,'model-details');
    await page.keyboard.press('Escape');
    assert(await page.locator('#popover').isVisible());
    await page.locator('.menubar span').first().click();
    assert(!(await page.locator('#popover').isVisible()));
    await page.locator('#menu-icon').click();
    await page.locator('#primary').click();

    await page.locator('#open-settings').click();
    const settings=page.frameLocator('#settings-frame');
    await settings.locator('[data-settings-tab="protection"]').click();
    await settings.getByLabel('When an agent is active').click();
    const pending=await settings.getByLabel('When an agent is active').isChecked();
    const force=settings.getByRole('checkbox',{name:'Force mode',exact:true});
    await force.check();
    assert.equal(await page.locator('#force-mode').textContent(),'End force mode');
    await force.uncheck();
    assert.equal(await settings.getByLabel('When an agent is active').isChecked(),pending);
    await settings.getByRole('button',{name:'Cancel',exact:true}).click();
    assert.equal(await page.locator('#primary').textContent(),'Start protection');

    for (const [scenario, visible] of [['mixed',true],['idle',false],['terminal',false],['checking',false]]) {
      await page.evaluate(value=>{ActivityPreview.scenario(value);},scenario);
      assert.equal(await page.locator('[data-agent-row]').count(),Number(visible));
    }
    await page.evaluate(()=>ActivityPreview.event('start'));
    assert(await page.locator('.pane-status-heading').getByText('Checking agent activity…').isVisible());

    await page.goto(base + '/activity.html#settings/general');
    const updates=settings.getByRole('group',{name:'Updates',exact:true});
    const automatic=updates.getByRole('checkbox',{name:'Automatically download updates'});
    const check=updates.getByRole('button',{name:'Check for Updates'});
    const install=updates.getByRole('button',{name:'Install Update…'});
    const updateStatus=updates.getByRole('status');
    const closeSettings=settings.getByRole('button',{name:'Close Settings'});
    const settingsWindow=settings.locator('.native-settings');
    const openSettings=()=>page.getByRole('button',{name:'Nightr Settings'}).click();
    await automatic.waitFor();
    assert(await updates.getByText('Build 8a41c2d').isVisible());
    assert(await automatic.isChecked());
    await capture(settingsWindow,'updates-general-dark');
    await page.evaluate(()=>document.querySelector('#theme').click());
    await capture(settingsWindow,'updates-general-light');
    await check.click();
    assert(await check.isDisabled());
    await updateStatus.getByText('Checking…').waitFor();
    await updateStatus.getByText('Downloading…').waitFor();
    await updateStatus.getByText('Update Ready').waitFor();
    assert(await install.isEnabled());
    await capture(settingsWindow,'updates-ready-light');
    await page.evaluate(()=>document.querySelector('#theme').click());
    await capture(settingsWindow,'updates-ready-dark');
    await automatic.uncheck();
    await install.click();
    assert(await settings.getByRole('heading',{name:'Save changes before updating?'}).isVisible());
    await settings.getByRole('button',{name:'Discard and Continue'}).click();
    assert(await settings.getByRole('heading',{name:'Install Nightr 0.1.1?'}).isVisible());
    await settings.locator('#modal-actions').getByRole('button',{name:'Cancel'}).click();
    assert(await automatic.isChecked());
    assert(await install.isVisible());
    await automatic.uncheck();
    await settings.getByRole('button',{name:'Save',exact:true}).click();
    await openSettings();
    assert(!(await automatic.isChecked()));
    await closeSettings.click();
    for (const [result, message] of [['offline','Couldn’t connect'],['unpublished','No published release'],['unverified','Couldn’t verify update']]) {
      await page.evaluate(value=>document.querySelector('#settings-frame').contentWindow.ActivitySettingsBridge.updateFixture(value),result);
      await page.evaluate(()=>document.querySelector('#settings-frame').contentWindow.ActivitySettingsBridge.backgroundUpdate());
      await openSettings();
      assert(await updateStatus.getByText('Not checked yet').isVisible());
      await check.click();
      await updateStatus.getByText(message,{exact:true}).waitFor();
      assert(await check.isEnabled());
      await closeSettings.click();
    }
    await openSettings();
    await settings.getByRole('button',{name:'Reset'}).click();
    assert(await automatic.isChecked());
    await settings.getByRole('button',{name:'Save',exact:true}).click();
    await page.evaluate(async()=>{
      const bridge=document.querySelector('#settings-frame').contentWindow.ActivitySettingsBridge;
      bridge.updateFixture('available');
      await bridge.backgroundUpdate();
    });
    assert(!(await page.locator('#settings').isVisible()));
    await openSettings();
    await updateStatus.getByText('Update Ready').waitFor();
    await install.click();
    await settings.getByRole('button',{name:'Simulate Install'}).click();
    assert(await updates.getByText('Build b71e506').isVisible());
    assert(await updateStatus.getByText('Up to date').isVisible());
    assert.deepEqual(failures,[]);
    console.log('Browser checks passed for both themes, Settings, update states, active-only Agent, Wi-Fi, model details and Force mode.');
  } finally {
    await browser?.close();
    server.close();
  }
}
run().catch(error => { console.error(error); process.exitCode=1; });
