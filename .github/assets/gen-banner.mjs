/**
 * Generates the README banners (house theme pair):
 *   excalidraw-banner.svg / .png      light 1600x500, white ground
 *   excalidraw-banner-dark.svg / .png dark  1600x500, GitHub-dark ground
 *
 * House standard: logo left, ink-left at x=165 and ink-centre at y=250, largest
 * ink dimension ~400px; the name to its right in the project's OWN font, sized
 * by CAP HEIGHT so every repo's name reads the same size; exactly one claim in
 * Lato underneath, grey. Nothing else on the banner.
 *
 * The name is set in Excalifont, Excalidraw's own hand-drawn face, because the
 * house rule is to use the real official font rather than a lookalike. It ships
 * as woff2, which opentype.js cannot read, so the generator fetches it and
 * converts it with fontTools (`pip install fonttools brotli`). Neither font is
 * committed: they are fetched at runtime and cached in the OS temp directory.
 *
 * The logo is Excalidraw's own favicon with its white rounded backing plate
 * removed, because a banner supplies its own ground and a plate inside it reads
 * as a sticker. Its ink box is measured rather than assumed: the artwork sits
 * inset in its viewBox, so placing it by the box would leave the logo visually
 * indented and smaller than every sibling repo's.
 *
 * Deps: `npm i -g @resvg/resvg-js opentype.js`, plus python3 with fontTools.
 * Run: node .github/assets/gen-banner.mjs
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const require = createRequire(import.meta.url);
const gRoot = execSync("npm root -g").toString().trim();
const { Resvg } = require(`${gRoot}/@resvg/resvg-js`);
const opentype = require(`${gRoot}/opentype.js`);

const __dir = dirname(fileURLToPath(import.meta.url));

// ---- content + styling -----------------------------------------------------
const NAME = "EXCALIDRAW"; // house standard: the name is set in caps
const CLAIM = "Hand-drawn diagrams that never phone home.";
const THEMES = [
  { suffix: "", bg: "#ffffff", name: "#1f2328", claim: "#5a5d5e" },
  { suffix: "-dark", bg: "#0d1117", name: "#e6edf3", claim: "#9aa4ad" },
];
const W = 1600, H = 500;
const INK = 400;        // largest ink dimension of the logo
const TARGET_CAP = 110; // cap height of the name, uniform across all repos
const claimSize = 44, gap = 70, lineGap = 8, startX = 165;

// Excalidraw's own faces, from its CDN. Pinned by the hashed filenames the build
// uses, so a silent upstream change cannot swap the artwork under the banner.
const CDN = "https://excalidraw.nyc3.cdn.digitaloceanspaces.com/oss/fonts";
const EXCALIFONT = `${CDN}/Excalifont/Excalifont-Regular-a88b72a24fb54c9f94e3b5fdaa7481c9.woff2`;
const LATO = "https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/lato/Lato-Regular.ttf";
// ---------------------------------------------------------------------------

async function fetchTo(url, path) {
  if (existsSync(path)) return path;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`fetch ${url}: ${res.status}`);
  writeFileSync(path, Buffer.from(await res.arrayBuffer()));
  return path;
}

async function loadTTF(url, cacheName) {
  const path = await fetchTo(url, join(tmpdir(), `excalidraw-${cacheName}.ttf`));
  const buf = readFileSync(path);
  return opentype.parse(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
}

// opentype.js reads TTF, the web ships woff2. fontTools does the one step in
// between; brotli is what actually decompresses the glyf table.
async function loadWOFF2(url, cacheName) {
  const woff2 = await fetchTo(url, join(tmpdir(), `excalidraw-${cacheName}.woff2`));
  const ttf = join(tmpdir(), `excalidraw-${cacheName}.ttf`);
  if (!existsSync(ttf)) {
    execSync(
      `python -c "from fontTools.ttLib import TTFont; f=TTFont(r'${woff2}'); f.flavor=None; f.save(r'${ttf}')"`,
      { stdio: "pipe" },
    );
  }
  const buf = readFileSync(ttf);
  return opentype.parse(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
}

// Glyph-by-glyph with manual kerning, and every path taken at the ORIGIN before
// being translated into place: opentype.js emits NaN control points for some
// glyph, size and POSITION combinations, and small coordinates never hit it.
function shapeRun(font, text, size) {
  const scale = size / font.unitsPerEm;
  const run = [];
  let x = 0, prev = null;
  for (const ch of text) {
    const g = font.charToGlyph(ch);
    if (prev) x += font.getKerningValue(prev, g) * scale;
    run.push({ g, x });
    x += g.advanceWidth * scale;
    prev = g;
  }
  return { run, width: x };
}
// One <path> per glyph, each one drawn at the ORIGIN and moved into place by its
// own transform. Two separate traps meet here and this sidesteps both:
// @resvg/resvg-js silently abandons a single path that merges many glyph
// subpaths partway through, and opentype.js emits literal NaN coordinates for
// some glyph-and-absolute-x combinations. The first attempt did neither and
// rendered "exc" of "excalidraw" and "Hand-drawn diagr." of the claim.
function glyphs(font, text, size) {
  return shapeRun(font, text, size).run
    .map(({ g, x }) => ({ d: g.getPath(0, 0, size).toPathData(2), x }))
    .filter((p) => p.d);
}
function paint(list, fill) {
  return list
    .map((p) => `<g transform="translate(${p.x.toFixed(1)}, 0)"><path d="${p.d}" fill="${fill}"/></g>`)
    .join("\n  ");
}

// Cap height from the font itself where it is declared, else measured off a
// capital. Point size says nothing about how big a name LOOKS, which is why
// sizing by it made some repos shout and others whisper.
function capRatio(font) {
  const declared = font.tables.os2 && font.tables.os2.sCapHeight;
  if (declared) return declared / font.unitsPerEm;
  const bb = font.charToGlyph("X").getPath(0, 0, font.unitsPerEm).getBoundingBox();
  return Math.abs(bb.y1) / font.unitsPerEm;
}

const nameFont = await loadWOFF2(EXCALIFONT, "excalifont");
const claimFont = await loadTTF(LATO, "lato");

// opentype.js's bezier flattening emits literal NaN control points for certain
// glyph-and-SIZE combinations, independently of where the glyph ends up: two
// letters of "excalidraw" came out NaN at the cap-fitted 183pt even when drawn
// at the origin. Stepping the size down by a fraction of a point clears it, and
// a fraction is invisible next to a 110px cap height, so the target stays what
// the house standard says and only genuinely broken sizes are stepped past.
function fitSize(font, text, start) {
  for (let size = start; size > start * 0.9; size -= 0.5) {
    const anyNaN = shapeRun(font, text, size).run.some(({ g }) =>
      g.getPath(0, 0, size).toPathData(2).includes("NaN"),
    );
    if (!anyNaN) return size;
  }
  throw new Error(`no NaN-free size for "${text}" near ${start}pt`);
}

// Cap height first, then width. The house target is a uniform cap height, but a
// long name in caps at that height simply does not fit next to a 400px logo:
// "EXCALIDRAW" wanted 1221px and ran 256px off the canvas. The standard's own
// answer is to shrink such a name until it leaves a right margin, so the fit
// wins over the target rather than the text running off the edge unnoticed.
const RIGHT_MARGIN = 80;
let nameSize = fitSize(nameFont, NAME, TARGET_CAP / capRatio(nameFont));
{
  // textX is not known yet, so use the widest the logo can push it to.
  const roomForText = W - (startX + INK + gap) - RIGHT_MARGIN;
  const natural = shapeRun(nameFont, NAME, nameSize).width;
  if (natural > roomForText) {
    nameSize = fitSize(nameFont, NAME, nameSize * (roomForText / natural));
  }
}
const nameW = shapeRun(nameFont, NAME, nameSize).width;
const claimW = shapeRun(claimFont, CLAIM, claimSize).width;

// --- the logo, without its backing plate ------------------------------------
let logo = readFileSync(join(__dir, "excalidraw-logo.svg"), "utf8")
  .replace(/<\?xml[^>]*\?>\s*/, "")
  // The white rounded rect is the favicon's plate, not part of the mark.
  .replace(/<rect[^>]*fill="#fff"[^>]*\/>\s*/i, "");

// Measure the ink rather than trusting the viewBox, then place by that.
const probe = new Resvg(logo, { fitTo: { mode: "width", value: 1000 } });
const bb = probe.innerBBox() || probe.getBBox();
if (!bb) throw new Error("could not measure the logo's ink box");
const scale = INK / Math.max(bb.width, bb.height);
const LW = 1000 * scale, LH = 1000 * scale;
const LX = startX - bb.x * scale;
const LY = H / 2 - (bb.y + bb.height / 2) * scale;
logo = logo.replace(
  /<svg[^>]*>/,
  `<svg x="${LX.toFixed(1)}" y="${LY.toFixed(1)}" width="${LW.toFixed(1)}" height="${LH.toFixed(1)}" viewBox="0 0 1000 1000" xmlns="http://www.w3.org/2000/svg">`,
);

const textX = startX + bb.width * scale + gap;
const em = (f, s) => s / f.unitsPerEm;
const nameAsc = nameFont.ascender * em(nameFont, nameSize);
const nameDesc = -nameFont.descender * em(nameFont, nameSize);
const claimAsc = claimFont.ascender * em(claimFont, claimSize);
const blockH = nameAsc + nameDesc + lineGap + claimAsc;
const nameBaseline = H / 2 - blockH / 2 + nameAsc;
const claimBaseline = nameBaseline + nameDesc + lineGap + claimAsc;

const nameGlyphs = glyphs(nameFont, NAME, nameSize);
const claimGlyphs = glyphs(claimFont, CLAIM, claimSize);
for (const [what, list] of [["name", nameGlyphs], ["claim", claimGlyphs]]) {
  const bad = list.filter((p) => p.d.includes("NaN"));
  if (bad.length) {
    throw new Error(`${what}: ${bad.length} glyph(s) still contain NaN coordinates`);
  }
}

const right = textX + Math.max(nameW, claimW);
if (right > W - 80) {
  console.warn(`warning: text reaches ${Math.round(right)}px of ${W}, margin is thin`);
}

for (const t of THEMES) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="excalidraw">
  <rect width="${W}" height="${H}" fill="${t.bg}"/>
  ${logo}
  <g transform="translate(${textX.toFixed(1)}, ${nameBaseline.toFixed(1)})">
  ${paint(nameGlyphs, t.name)}
  </g>
  <g transform="translate(${textX.toFixed(1)}, ${claimBaseline.toFixed(1)})">
  ${paint(claimGlyphs, t.claim)}
  </g>
</svg>
`;
  writeFileSync(join(__dir, `excalidraw-banner${t.suffix}.svg`), svg);
  const png = new Resvg(svg, { fitTo: { mode: "width", value: W }, background: t.bg }).render().asPng();
  writeFileSync(join(__dir, `excalidraw-banner${t.suffix}.png`), png);
  console.log(
    `wrote excalidraw-banner${t.suffix}.svg + .png ` +
    `(logo ink ${Math.round(bb.width * scale)}x${Math.round(bb.height * scale)}, ` +
    `name ${Math.round(nameW)}px at ${Math.round(nameSize)}pt, right edge ${Math.round(right)})`,
  );
}
