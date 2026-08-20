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
                        'public/data/cracks_daily.json',
                        'public/data/retail.json', 'public/data/fx.json',
                        'public/data/usregions.json']) {
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
// Läses ur filen, inte ur sidan: annars jämförs sidan med sig själv.
const retailJson = JSON.parse(fs.readFileSync(path.join(SITE, 'public/data/retail.json'), 'utf8'));
const retailWeeksLast = (() => {
  let last = null;
  for (const s of retailJson.series)
    s.values.forEach((v, i) => { if (v !== null && (last === null || i > last)) last = i; });
  return retailJson.weeks[last];
})();
const fails = [];
const check = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'}  ${msg}`); if (!ok) fails.push(msg); };

check(doc.querySelectorAll('.failed').length === 0,
      'data loaded (no failure banner): ' + (doc.querySelector('.failed')?.textContent ?? ''));
check(doc.querySelectorAll('.chart').length === 4, 'four charts mounted');
check(doc.querySelectorAll('canvas').length === 4, 'four ECharts canvases');
check(doc.querySelectorAll('.prov').length >= 4, 'provenance under every chart');
// 20 = de 18 tidigare plus Scale (Weekly/Daily). Linjalens On/Off finns bara i
// dagsläget och räknas därför inte här — den kontrolleras när den ska dyka upp.
check(doc.querySelectorAll('.group button').length === 20, 'all toggles present');
check(errors.length === 0, 'no errors on first render: ' + errors.slice(0, 2).join(' | '));

// Rubrikstämpeln och täckningsraderna. Axelns slut duger inte som täckning —
// veckoaxeln går till senaste retailvecka medan crack-serien slutar tidigare —
// så det som kontrolleras är att de faktiskt kan skilja sig åt.
const stamp = doc.querySelector('#datastamp');
check(!!stamp && /Updated \d{4}-\d{2}-\d{2}/.test(stamp.textContent),
      'header states when it was updated: ' + (stamp?.textContent ?? ''));
check(!!stamp && /weekly \d{4}-\d{2}-\d{2} – \d{4}-\d{2}-\d{2}/.test(stamp.textContent),
      'header states the weekly coverage');
check(!!stamp && /daily to \d{4}-\d{2}-\d{2}/.test(stamp.textContent),
      'header states the daily coverage');

check(doc.querySelectorAll('.cover').length === 4 &&
      [...doc.querySelectorAll('.cover')].every(p => /covers \d{4}-\d{2}-\d{2} – /.test(p.textContent)),
      'all four charts state their own coverage');

// Crack-täckningen MÅSTE kunna sluta tidigare än retail: EIA ligger efter och
// min_week_obs tar bort ofullständiga veckor. Slutar de på samma vecka har
// antingen datan råkat vara i fas eller så skrivs axeln ut i stället för
// täckningen — det senare är buggen, så jämförelsen görs mot retailaxeln.
const coverEnd = sel => {
  const m = doc.querySelector(sel + ' .cover').textContent.match(/covers \S+ – (\S+)/);
  return m && m[1];
};
check(coverEnd('#cracks') <= coverEnd('#retail'),
      `crack coverage does not run past retail (${coverEnd('#cracks')} vs ${coverEnd('#retail')})`);
check(coverEnd('#retail') === retailWeeksLast,
      `retail coverage ends at its last published week (${coverEnd('#retail')} vs ${retailWeeksLast})`);

const click = (label, scope) => {
  const root = scope ? doc.querySelector(scope) : doc;
  const b = [...root.querySelectorAll('.group button')].find(x => x.textContent === label);
  if (!b) { fails.push(`missing control: ${label}${scope ? ' in ' + scope : ''}`); return false; }
  b.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  return true;
};
const step = async (label, expectEmpty, scope) => {
  const before = errors.length;
  if (!click(label, scope)) return;
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
// --- dagsläget och 7-dagarslinjalen ---------------------------------------
//
// Serieantalet är hela poängen: linjalen måste lägga TILL en linje per spread,
// inte ersätta dagslinjen. Ett reglage som bara byter tjocklek på samma serie
// hade sett rätt ut i ett skärmklipp och varit fel.
const crackSeries = () =>
  echarts.getInstanceByDom(doc.querySelector('#cracks .chart')).getOption().series.length;

await step('Daily', 0);
check(crackSeries() === 4, `daily+ruler draws 2 spreads and 2 rulers (got ${crackSeries()})`);
check(/Last EIA observation \d{4}-\d{2}-\d{2}/.test(doc.querySelector('#cracks').textContent),
      'daily view states the last observation date');
check(/\d+ days before this refresh/.test(doc.querySelector('#cracks').textContent),
      'daily view states the lag in days');

await step('Off', 0, '#cracks');
check(crackSeries() === 2, `ruler off leaves the daily lines only (got ${crackSeries()})`);
check(!/7-day/.test(JSON.stringify(
        echarts.getInstanceByDom(doc.querySelector('#cracks .chart')).getOption().series
          .map(x => x.name))),
      'ruler off removes the 7d series, not just its colour');

await step('On', 0, '#cracks');
await step('NW Europe', 1);          // saknar ICE-data i dagsläget också
await step('US (NYH)', 0);
await step('Weekly', 0);
check(!doc.querySelector('#cracks').textContent.includes('Last EIA observation'),
      'the lag line belongs to the daily view only');

await step('Petrol (E95)');

// Utan skatt saknar USA serie — EIA publicerar bara pumppriset, som redan
// innehåller skatt. Noten måste namnge landet; "1 region(s) omitted" fick en
// läsare att tro att USA-kurvan försvunnit av misstag.
await step('Without tax');
const note = doc.querySelector('#retail .note-inline');
check(!!note, 'without-tax shows an explanatory note');
check(!!note && /United States/.test(note.textContent),
      'the note names the country that is missing: ' + (note?.textContent ?? '').slice(0, 70));

await step('With tax');
check(!doc.querySelector('#retail .note-inline'), 'the note disappears again with tax');

for (const l of ['SEK', 'USD', 'Diesel', 'EUR']) await step(l);

// Regional spridning: geografin skiljer sig mellan bränslena och noten måste
// följa med, annars läser man PADD-regioner som delstater.
await step('Petrol (regular)', undefined, '#usregions');
const geoNote = () => doc.querySelector('#usregions .note-inline')?.textContent ?? '';
check(/Nine states/.test(geoNote()), 'petrol view says nine states');
await step('Diesel', undefined, '#usregions');
check(/Regions, not states/.test(geoNote()), 'diesel view says PADD regions, not states');
await step('Petrol (regular)', undefined, '#usregions');

// Tooltipplacering. På telefon är diagrammet ~300 px högt och en axel-tooltip
// med fyra serier lägger sig annars mitt över kurvorna man just pekade på —
// rapporterat från iPhone på "rockets and feathers".
const chartNames = ['crack', 'retail', 'usregions', 'rockets'];
[...doc.querySelectorAll('.chart')].forEach((d, i) => {
  const inst = echarts.getInstanceByDom(d);
  const pos = [].concat(inst.getOption().tooltip)[0].position;
  if (typeof pos !== 'function') { check(false, `${chartNames[i]}: tooltip has no position function`); return; }
  const size = (cw, ch, tw, th) => ({ viewSize: [cw, ch], contentSize: [tw, th] });
  const L = pos([50, 200], null, null, null, size(360, 300, 200, 90));
  const R = pos([300, 200], null, null, null, size(360, 300, 200, 90));
  const C = pos([880, 360], null, null, null, size(900, 380, 200, 90));
  check(L[1] === 6 && R[1] === 6, `${chartNames[i]}: phone tooltip pinned to the top`);
  check(L[0] > R[0], `${chartNames[i]}: phone tooltip sits opposite the finger`);
  check(C[0] + 200 <= 900 && C[1] + 90 <= 380, `${chartNames[i]}: desktop tooltip stays inside`);
});

server.close();
console.log(fails.length ? `\n${fails.length} FAILED` : '\nalla rökprov gröna');
process.exit(fails.length ? 1 : 0);
