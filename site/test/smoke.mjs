// Headless rökprov: kör den riktiga Scala.js-appen i jsdom mot den riktiga
// publicerade datan, och klickar igenom varje reglage.
//
// Detta är enda testet av frontend som faktiskt kör koden. Det tjänade in sig
// direkt: det fann att obegränsade visualMap-bitar ({lt}, {gte} utan min/max)
// får ECharts getVisualGradient att kasta och fälla hela tröskeldiagrammet —
// ett fel som varken kompilatorn eller ett ögonkast på options ser.
//
// Kör:  cd site/test && npm install && npm test
// Kräver att site/public/app.js är länkad (./mill site.bundleFast) och att
// site/public/data/*.json finns (pipeline/run.sh).

import { JSDOM } from 'jsdom';
import * as echarts from 'echarts';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json' };

for (const required of ['public/app.js', 'public/data/cracks.json',
                        'public/data/retail.json', 'public/data/fx.json']) {
  if (!fs.existsSync(path.join(SITE, required))) {
    console.error(`saknas: site/${required} — kör ./mill site.bundleFast och pipeline/run.sh först`);
    process.exit(2);
  }
}

const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  const file = path.join(SITE, rel);
  if (!file.startsWith(SITE) || !fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] ?? 'application/octet-stream' });
  res.end(fs.readFileSync(file));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const BASE = `http://127.0.0.1:${server.address().port}`;

// ECharts injiceras som modul i stället för via CDN-taggen; app.js laddas
// explicit nedan så att globalerna hinner sättas först.
const html = fs.readFileSync(path.join(SITE, 'index.html'), 'utf8')
  .replace(/<script src="https:\/\/cdn[^>]*><\/script>/, '')
  .replace(/<script src="public\/app.js"><\/script>/, '');

const dom = new JSDOM(html, { url: BASE + '/', runScripts: 'outside-only', pretendToBeVisual: true });
const w = dom.window;

const nativeFetch = globalThis.fetch;
w.fetch = (u, o) => nativeFetch(new URL(u, BASE).href, o);
w.echarts = echarts;
// jsdom mäter allt till 0x0; ECharts vägrar rita i en nollstor container.
w.HTMLElement.prototype.getBoundingClientRect = () =>
  ({ width: 900, height: 380, top: 0, left: 0, right: 900, bottom: 380, x: 0, y: 0 });
Object.defineProperty(w.HTMLElement.prototype, 'clientWidth', { get: () => 900 });
Object.defineProperty(w.HTMLElement.prototype, 'clientHeight', { get: () => 380 });

const errors = [];
w.addEventListener('error', e => errors.push(e.message));
const origErr = console.error;
console.error = (...a) => { errors.push(a.join(' ').split('\n')[0]); };

globalThis.window = w;
globalThis.document = w.document;
globalThis.self = w;
globalThis.echarts = echarts;
globalThis.fetch = w.fetch;
Object.defineProperty(globalThis, 'navigator', { value: w.navigator, configurable: true });

new w.Function(fs.readFileSync(path.join(SITE, 'public/app.js'), 'utf8')).call(w);
await new Promise(r => setTimeout(r, 3000));

const doc = w.document;
const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'}  ${msg}`); if (!ok) fails.push(msg); };

check(doc.querySelectorAll('.failed').length === 0,
      'data loaded (no failure banner): ' + (doc.querySelector('.failed')?.textContent ?? ''));
check(doc.querySelectorAll('.chart').length === 3, 'three charts mounted');
check(doc.querySelectorAll('canvas').length === 3, 'three ECharts canvases');
check(doc.querySelectorAll('.prov').length === 3, 'provenance under every chart');
check(doc.querySelectorAll('.group button').length === 13, 'all toggles present');
check(errors.length === 0, 'no errors on first render: ' + errors.slice(0, 2).join(' | '));

const click = label => {
  const b = [...doc.querySelectorAll('.group button')].find(x => x.textContent === label);
  if (!b) { fails.push(`missing control: ${label}`); return false; }
  b.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  return true;
};
const step = async (label, expectEmpty) => {
  const before = errors.length;
  if (!click(label)) return;
  await new Promise(r => setTimeout(r, 80));
  const empty = doc.querySelectorAll('.empty').length;
  check(errors.length === before, `"${label}" renders without error` +
        (errors.length > before ? ': ' + errors[before] : ''));
  if (expectEmpty !== undefined)
    check(empty === expectEmpty, `"${label}" -> empty state ${expectEmpty} (got ${empty})`);
};

// Ordningen är avsiktlig: NWE saknar ICE-data och ska ge tomtillståndet i BÅDA
// lägena, och vägen tillbaka till US ska återställa diagrammet.
await step('Line', 0);
await step('NW Europe', 1);
await step('Threshold', 1);
await step('US (NYH)', 0);
await step('NYH ULSD – WTI', 0);
for (const l of ['Petrol (E95)', 'Without tax', 'SEK', 'USD', 'Diesel', 'With tax', 'EUR'])
  await step(l);

server.close();
console.log(fails.length ? `\n${fails.length} FAILED` : '\nalla rökprov gröna');
process.exit(fails.length ? 1 : 0);
