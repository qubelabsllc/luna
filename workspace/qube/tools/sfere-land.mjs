// Works out which Sfere Squares are land and writes the answer for the site and the database:
//   data/sfere-land.json     read by the globe (sfere.html)
//   supabase/006_land.sql    the same list, for sfere_is_land()
//
// A Square is land when at least 4 of 64 sample points (8 × 8) across it fall on
// land in data/land-50m.json, drawn at 8192 × 4096. It runs in headless Chromium,
// because that's the same canvas and d3-geo drawing the globe uses.
//
//   npm i -g playwright   (or point PLAYWRIGHT at an existing install)
//   node workspace/qube/tools/sfere-land.mjs
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));
const Q = path.resolve(here, "..");
const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");

const CDN = "https://cdn.jsdelivr.net/npm/";
const page = `<script>window.QUBE_CONFIG = {}</script>
<script src="${CDN}d3-array@3.2.4/dist/d3-array.min.js"></script>
<script src="${CDN}d3-geo@3.1.1/dist/d3-geo.min.js"></script>
<script src="${CDN}topojson-client@3.1.0/dist/topojson-client.min.js"></script>
<script src="/qube.js"></script>`;

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const tab = await browser.newPage();
await tab.route("http://sfere.local/**", (r) => {
  const p = new URL(r.request().url()).pathname;
  if (p === "/") return r.fulfill({ contentType: "text/html", body: page });
  if (p === "/qube.js") return r.fulfill({ path: path.join(Q, "qube.js") });
  if (p === "/land.json") return r.fulfill({ path: path.join(Q, "data/land-50m.json") });
  return r.fulfill({ status: 404 });
});
// Offline? Set LIBS to a folder of unpacked npm tarballs (LIBS/d3-geo-3.1.1/package/…).
if (process.env.LIBS) await tab.route(CDN + "**", (r) => {
  const [, name, ver, rest] = new URL(r.request().url()).pathname.match(/^\/npm\/(.+?)@([^/]+)\/(.+)$/);
  r.fulfill({ path: path.join(process.env.LIBS, `${name}-${ver}`, "package", rest) });
});
await tab.goto("http://sfere.local/");

const runs = await tab.evaluate(async () => {
  const topo = await (await fetch("/land.json")).json();
  const land = topojson.feature(topo, topo.objects.land);
  const W = 8192, H = 4096, K = 8, MIN = 4;
  const canvas = document.createElement("canvas");
  canvas.width = W; canvas.height = H;
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#000"; ctx.fillRect(0, 0, W, H);
  const proj = d3.geoEquirectangular().scale(W / (2 * Math.PI)).translate([W / 2, H / 2]).precision(0.1);
  ctx.fillStyle = "#fff"; ctx.beginPath(); d3.geoPath(proj, ctx)(land); ctx.fill();
  const img = ctx.getImageData(0, 0, W, H).data;

  const g = QUBE.grid;
  const out = [];   // gaps and run lengths, alternating: water, land, water, land, …
  let last = 0, start = -1;
  for (let i = 0; i <= g.TOTAL; i++) {
    let on = false;
    if (i < g.TOTAL) {
      const row = Math.floor(i / g.N), col = i % g.N;
      let hits = 0;
      for (let a = 0; a < K && hits < MIN; a++) for (let b = 0; b < K; b++) {
        const v = g.dir(row, col, (a + 0.5) / K, (b + 0.5) / K);
        const lat = (Math.asin(Math.max(-1, Math.min(1, v[1]))) * 180) / Math.PI;
        const lon = (Math.atan2(-v[2], v[0]) * 180) / Math.PI;
        const x = Math.min(W - 1, Math.floor(((lon + 180) / 360) * W));
        const y = Math.min(H - 1, Math.floor(((90 - lat) / 180) * H));
        if (img[(y * W + x) * 4] > 127) hits++;
      }
      on = hits >= MIN;
    }
    if (on && start < 0) start = i;
    if (!on && start >= 0) { out.push(start - last, i - start); last = i; start = -1; }
  }
  return out;
});
await browser.close();

let cells = 0;
for (let i = 1; i < runs.length; i += 2) cells += runs[i];
fs.writeFileSync(path.join(Q, "data/sfere-land.json"), JSON.stringify({ n: 573, cells, runs }) + "\n");
const sqlPath = path.join(Q, "supabase/006_land.sql");
const sql = fs.readFileSync(sqlPath, "utf8").replace(/unnest\(array\[[^\]]*\]::integer\[\]\)/, `unnest(array[${runs.join(",")}]::integer[])`);
fs.writeFileSync(sqlPath, sql);
console.log(`${cells.toLocaleString("en-US")} land Squares in ${runs.length / 2} runs`);
