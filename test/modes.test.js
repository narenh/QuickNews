// node --test test/
// Per-site modes through background.js, driven by test/fake-browser.js.
const test = require('node:test');
const assert = require('node:assert');
const { load } = require('./fake-browser.js');
const ARTICLE = 'https://www.wsj.com/politics/some-long-article-slug-here';
const hit = async () => 'A1';
const plain = (v) => JSON.parse(JSON.stringify(v ?? null)); // objects from the vm context aren't deep-equal across realms
const settle = () => new Promise((r) => setTimeout(r, 0)); // lets fire-and-forget work finish
const check = (b, url = ARTICLE) => b.message({ action: 'checkPage', url }, { tab: { id: 1 } });

test('a fresh install opens seed sites automatically and stores the map', async () => {
  const b = load(hit);
  assert.deepStrictEqual(plain(await check(b)), { id: 'A1', openNow: true });
  assert.strictEqual(b.store.modes['wsj.com'], 'auto');
});

test('ask: the id comes back but News is not opened', async () => {
  const b = load(hit, { store: { modes: { 'wsj.com': 'ask' } } });
  assert.deepStrictEqual(plain(await check(b)), { id: 'A1', openNow: false });
});

test('off, and a seed site missing from the stored map: no lookup', async () => {
  let calls = 0;
  const b = load(async () => { calls++; return 'A1'; }, { store: { modes: { 'wired.com': 'auto' } } });
  assert.strictEqual(await check(b), null);
  const off = load(hit, { store: { modes: { 'wsj.com': 'off' } } });
  assert.strictEqual(await check(off), null);
  assert.strictEqual(calls, 0);
});

test('old settings are migrated on first use', async () => {
  const b = load(hit, { store: { sites: { 'wsj.com': true, 'wired.com': true }, manual: { 'wired.com': true } } });
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'www.wired.com' })), { site: 'wired.com', mode: 'ask' });
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'www.wsj.com' })), { site: 'wsj.com', mode: 'auto' });
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'nymag.com' })), { site: 'nymag.com', mode: 'off' });
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'www.example.org' })), { site: 'example.org', mode: 'off' });
});

test('setMode changes the site and rejects an invalid mode', async () => {
  const b = load(hit, { store: { modes: {} } });
  await b.message({ action: 'setMode', site: 'example.org', mode: 'ask' });
  assert.strictEqual(b.store.modes['example.org'], 'ask');
  await b.message({ action: 'setMode', site: 'example.org', mode: 'bogus' });
  assert.strictEqual(b.store.modes['example.org'], 'ask');
});


// A stand-in for the native handler and the app group it shares with the app.
function appGroup(initial) {
  const group = { modes: initial, sent: [] };
  group.native = (m) => {
    group.sent.push(m);
    switch (m.action) {
      case 'resolve': return { found: true, id: 'A1' };
      case 'settings': return group.modes ? { modes: group.modes } : { stored: false };
      case 'setModes': group.modes ??= { ...m.modes }; return { modes: group.modes };
      case 'setMode': group.modes = { ...group.modes, [m.site]: m.mode }; return {};
      default: return {};
    }
  };
  return group;
}

test('Safari records seen for seed and custom sites in any mode, not for others', async () => {
  const b = load(hit, { native: appGroup({ 'wsj.com': 'off', 'custom.com': 'ask' }).native });
  await check(b, 'https://www.wsj.com/news/world');
  await settle();
  assert.ok(b.store.seen['wsj.com'] > 0);
  const c = load(hit, { native: appGroup({ 'custom.com': 'off' }).native });
  for (const url of ['https://custom.com/', 'https://wired.com/', 'https://other.example/']) { await check(c, url); await settle(); }
  assert.deepStrictEqual(Object.keys(c.store.seen).sort(), ['custom.com', 'wired.com']);
});

test('Chrome records no visits: it has no app to show them', async () => {
  const b = load(hit, { store: { modes: { 'wsj.com': 'auto' } } });
  await check(b);
  await settle();
  assert.ok(!('seen' in b.store) && !('active' in b.store));
});

test('Safari reads the modes from the app group, so the app\'s edits apply at once', async () => {
  const group = appGroup({ 'wsj.com': 'ask' });
  const b = load(hit, { native: group.native, store: { modes: { 'wsj.com': 'auto' } } });
  assert.deepStrictEqual(plain(await check(b)), { id: 'A1', openNow: false });
  group.modes = { 'wsj.com': 'auto' }; // changed in the app
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'www.wsj.com' })), { site: 'wsj.com', mode: 'auto' });
});

test('Safari hands an empty app group the settings from an older build, once', async () => {
  const group = appGroup(undefined);
  const b = load(hit, { native: group.native, store: { sites: { 'wsj.com': true }, manual: { 'wsj.com': true } } });
  assert.deepStrictEqual(plain(await b.message({ action: 'siteStatus', host: 'wsj.com' })), { site: 'wsj.com', mode: 'ask' });
  assert.deepStrictEqual(plain(group.modes), { 'wsj.com': 'ask' });
  await b.message({ action: 'siteStatus', host: 'wsj.com' });
  assert.strictEqual(group.sent.filter((m) => m.action === 'setModes').length, 1);
});

test('Safari\'s popup writes to the app group; reports carry no modes', async () => {
  const group = appGroup({ 'wsj.com': 'auto' });
  const b = load(hit, { native: group.native });
  await b.message({ action: 'setMode', site: 'wsj.com', mode: 'off' });
  assert.strictEqual(group.modes['wsj.com'], 'off');
  assert.ok(!('modes' in b.store));
  group.modes = { 'wsj.com': 'auto' };
  await check(b);
  const sync = group.sent.find((m) => m.action === 'sync');
  assert.ok(sync && !('modes' in sync.state) && !('modesAt' in sync.state));
});
