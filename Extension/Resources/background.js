/*
 * Decides whether a page should open in News, using owl.js to look it up in
 * Apple's index. A page is only looked up on sites whose mode is ask or auto;
 * a miss means News has no copy, so the page is left alone.
 */

const COOLDOWN_MS = 15 * 60 * 1000; // don't auto-open the same URL twice in this window
const SYNC_INTERVAL_MS = 10 * 60 * 1000; // report activity to the app at most this often
const APP_ID = 'com.canopysf.AutoOpenInNews';

// Safari extensions come with a native handler; Chrome's has none.
const IS_SAFARI = browser.runtime.getURL('').startsWith('safari-web-extension:');

/*
 * The site modes. In Safari they live in the app group, which the app edits
 * too, so they're read through the native handler every time. Chrome, which
 * has no app, keeps them in extension storage.
 */
async function settings() {
  if (IS_SAFARI) {
    const reply = await browser.runtime.sendNativeMessage(APP_ID, { action: 'settings' }).catch(() => null);
    if (reply?.modes) return { modes: cleanModes(reply.modes) };
    if (reply?.stored === false) {
      // Nothing saved yet: hand over this extension's own settings, from an older
      // build or the defaults. The handler keeps whatever got there first.
      const handed = await browser.runtime.sendNativeMessage(APP_ID, { action: 'setModes', modes: await localModes() }).catch(() => null);
      if (handed?.modes) return { modes: cleanModes(handed.modes) };
    }
  }
  return { modes: await localModes() };
}

/* Modes kept in extension storage: Chrome's, and Safari's before the app group held them. */
async function localModes() {
  const stored = await browser.storage.local.get(['sites', 'auto', 'manual', 'modes']);
  const { modes, migrated } = modesFrom(stored, self.SEED_SITES);
  if (migrated) await browser.storage.local.set({ modes });
  return modes;
}

/* The sites that have a mode, plus the seed sites, which are off unless the map says otherwise. */
function knownSites(modes) {
  return { ...Object.fromEntries(self.SEED_SITES.map((s) => [s, 'off'])), ...modes };
}

/* The known site that covers this host: itself or its nearest parent. */
function siteFor(host, sites) {
  for (let h = host; h.includes('.'); h = h.slice(h.indexOf('.') + 1)) {
    if (h in sites) return h;
  }
  return null;
}

/*
 * Article URLs end in a slug or a numeric ID; section fronts don't. Checking
 * this first saves fetching an index bucket for every page on a site.
 */
function hasArticleSlug(url) {
  const last = url.pathname.split('/').filter(Boolean).pop() ?? '';
  return (last.match(/-/g) ?? []).length >= 3 || /\d{6,}/.test(last);
}

const lookups = new Map(); // url -> Promise<article ID, null if not in News, undefined if the lookup failed>

/*
 * In Safari the native handler does the lookup (OWLResolver.swift), so the
 * request comes from the app extension rather than a browser context. owl.js
 * covers Chrome, and Safari if the native lookup fails.
 */
async function nativeLookup(url) {
  if (!IS_SAFARI) return null;
  const reply = await browser.runtime.sendNativeMessage(APP_ID, { action: 'resolve', url }).catch(() => null);
  return typeof reply?.found === 'boolean' ? reply : null;
}

async function resolve(url) {
  const native = await nativeLookup(url);
  const id = native ? (native.found ? native.id : null) : await owlResolve(url).catch(() => undefined);
  syncToApp().catch(() => {});
  return id;
}

/* Hits and misses are kept; a failed lookup is dropped so the next visit tries again. */
function lookup(url) {
  if (!lookups.has(url)) {
    const pending = resolve(url);
    lookups.set(url, pending);
    pending.then((id) => { if (id === undefined) lookups.delete(url); }, () => lookups.delete(url));
  }
  return lookups.get(url);
}

/*
 * The app shows where the extension has run and its website access, which
 * Safari doesn't expose to it. Each report replaces the last one.
 */
async function syncToApp() {
  if (!IS_SAFARI) return;
  const { seen = {}, active = 0 } = await browser.storage.local.get(['seen', 'active']);
  const access = await websiteAccess();
  await browser.runtime.sendNativeMessage(APP_ID, { action: 'sync', state: { seen, active, ...(access && { access }) } });
  await browser.storage.local.set({ reportedAccess: access });
}

/*
 * Which websites Safari lets the extension run on, as far as it says: "all",
 * "some" or "none". Null when the browser can't tell.
 */
async function websiteAccess() {
  const origins = (await browser.permissions?.getAll?.().catch(() => null))?.origins;
  if (!Array.isArray(origins)) return null;
  if (origins.some((o) => o === '<all_urls>' || o === '*://*/*' || o === 'https://*/*')) return 'all';
  return origins.some((o) => o !== 'https://news-assets.apple.com/*') ? 'some' : 'none';
}

/* Records that the extension ran (on a known site, if given), reporting it when stale. */
async function noteActivity(site) {
  if (!IS_SAFARI) return; // only the Safari app shows where the extension ran
  const now = Date.now();
  const { seen = {}, active = 0 } = await browser.storage.local.get(['seen', 'active']);
  const stale = (t) => now - (t ?? 0) > SYNC_INTERVAL_MS;
  const due = stale(active) || (site && stale(seen[site]));
  if (due) await browser.storage.local.set({ active: now, ...(site && { seen: { ...seen, [site]: now } }) });
  // A change in website access is reported straight away.
  const { reportedAccess } = await browser.storage.local.get(['reportedAccess']);
  if (due || (await websiteAccess()) !== (reportedAccess ?? null)) await syncToApp();
}

async function setTabIcon(tabId, id) {
  const { path, title } = iconFor(id, browser.runtime.getManifest());
  await Promise.all([browser.action.setIcon({ tabId, path }), browser.action.setTitle({ tabId, title })]);
}

/*
 * Grays the tab's icon for a page News lacks, unless the tab has moved on to
 * another page. Query and fragment are ignored: sites often rewrite them in place.
 */
async function showMissing(tabId, url) {
  if (tabId === undefined) return;
  const page = (u) => { const { origin, pathname } = new URL(u); return origin + pathname; };
  const tab = await browser.tabs.get(tabId);
  if (tab.url && page(tab.url) === page(url)) await setTabIcon(tabId, null);
}

async function checkPage(urlString, tabId) {
  const url = new URL(urlString);
  const current = await settings();
  const { modes } = current;
  const site = siteFor(url.hostname, knownSites(modes));
  noteActivity(site).catch(() => {});
  if (modeFor(modes, site) === 'off' || !hasArticleSlug(url)) return null;

  const id = await lookup(urlString);
  if (id === null) showMissing(tabId, urlString).catch(() => {});
  if (!id) return null;

  const { opened = {} } = await browser.storage.local.get(['opened']);
  const now = Date.now();
  const openNow = autoOpens(current, site) && !(now - (opened[urlString] ?? 0) < COOLDOWN_MS);
  if (openNow) {
    const recent = Object.fromEntries(Object.entries(opened).filter(([, t]) => now - t < COOLDOWN_MS));
    await browser.storage.local.set({ opened: { ...recent, [urlString]: now } });
  }
  return { id, openNow };
}

/* Opens News from the native handler, which only does so on the Mac. */
async function openArticle(id) {
  if (!IS_SAFARI) return { opened: false };
  const reply = await browser.runtime.sendNativeMessage(APP_ID, { action: 'open', id }).catch(() => null);
  return { opened: reply?.opened === true };
}

async function siteStatus(host) {
  const { modes } = await settings();
  const site = siteFor(host, knownSites(modes));
  return { site: site ?? host.replace(/^www\./, ''), mode: modeFor(modes, site) };
}

async function setMode(site, mode) {
  if (!MODES.includes(mode)) return;
  if (IS_SAFARI) {
    await settings(); // makes sure the app group holds the settings before changing one
    const reply = await browser.runtime.sendNativeMessage(APP_ID, { action: 'setMode', site, mode }).catch(() => null);
    if (reply) return;
  }
  const modes = await localModes();
  await browser.storage.local.set({ modes: { ...modes, [site]: mode } });
}

const handlers = {
  checkPage: (m, sender) => checkPage(m.url, sender.tab?.id),
  lookup: async (m) => ({ id: await lookup(m.url) }),
  open: (m) => openArticle(m.id),
  siteStatus: (m) => siteStatus(m.host),
  setMode: (m) => setMode(m.site, m.mode)
};

// Callback style: Chrome ignores a promise returned from the listener.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const handler = handlers[message.action];
  if (!handler) return false;
  Promise.resolve(handler(message, sender)).then(sendResponse, (e) => sendResponse({ error: String(e) }));
  return true;
});

// Website access can change in Safari's settings at any time; tell the app.
browser.permissions?.onAdded?.addListener(() => syncToApp().catch(() => {}));
browser.permissions?.onRemoved?.addListener(() => syncToApp().catch(() => {}));
browser.runtime.onStartup?.addListener(() => syncToApp().catch(() => {}));
browser.runtime.onInstalled?.addListener(() => syncToApp().catch(() => {}));

// A new page starts with the normal icon; checkPage grays it if News lacks it.
browser.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading') setTabIcon(tabId, undefined).catch(() => {});
});
