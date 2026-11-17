// Loads the real background.js against a fake browser, with the lookup stubbed.
const fs = require('node:fs');
const vm = require('node:vm');
const R = `${__dirname}/../Extension/Resources/`;

// `store` seeds the extension's storage; `native` makes it a Safari extension whose native handler is that function.
function load(owlResolve, { store = {}, native = null } = {}) {
  const tabs = {}, icons = {};
  let onMessage, onUpdated;
  const browser = {
    runtime: {
      getURL: () => (native ? 'safari-web-extension://x/' : 'chrome-extension://x/'),
      sendNativeMessage: async (id, m) => native(m),
      getManifest: () => JSON.parse(fs.readFileSync(R + 'manifest.json', 'utf8')),
      onMessage: { addListener: (f) => { onMessage = f; } }
    },
    storage: { local: { get: async (keys) => Object.fromEntries(keys.filter((k) => k in store).map((k) => [k, store[k]])), set: async (o) => Object.assign(store, o) } },
    tabs: {
      get: async (id) => (id in tabs ? { id, url: tabs[id] } : Promise.reject(new Error('no tab'))),
      onUpdated: { addListener: (f) => { onUpdated = f; } }
    },
    action: {
      setIcon: async ({ tabId, path }) => { icons[tabId] = { ...icons[tabId], gray: path[16].includes('gray') }; },
      setTitle: async ({ tabId, title }) => { icons[tabId] = { ...icons[tabId], title }; }
    }
  };
  const ctx = vm.createContext({ browser, console, URL, Date, Promise, Object, Map, Boolean, String, JSON });
  ctx.self = ctx;
  for (const f of ['sites.js', 'autoopen.js', 'icon.js', 'background.js']) vm.runInContext(fs.readFileSync(R + f, 'utf8'), ctx);
  ctx.owlResolve = owlResolve;
  const settle = () => new Promise((r) => setTimeout(r, 10));
  const message = (m, sender = {}) => new Promise((res) => onMessage(m, sender, res));
  return {
    icons, store,
    async visit(tabId, url, { tabUrl = url } = {}) {
      if (tabUrl) { tabs[tabId] = tabUrl; onUpdated(tabId, { status: 'loading' }); }
      await message({ action: 'checkPage', url }, { tab: { id: tabId } });
      await settle();
    },
    async navigate(tabId, url) { tabs[tabId] = url; onUpdated(tabId, { status: 'loading' }); await settle(); },
    message
  };
}

module.exports = { load };
