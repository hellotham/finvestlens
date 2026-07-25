/**
 * Generates the online manual from the app's own help book.
 *
 * HelpContent.swift is the single source of truth for both the in-app help and
 * this site, so the manual cannot drift from the app it documents. Re-run after
 * editing the help:  node scripts/build-manual.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const SOURCE = resolve(here, '../../Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift');
const OUT = resolve(here, '../src/data/manual.json');

const swift = readFileSync(SOURCE, 'utf8');

/** Reads a Swift string literal — plain "…" or a """ block with \-continuations. */
function readString(text, i) {
  if (text.startsWith('"""', i)) {
    const end = text.indexOf('"""', i + 3);
    const body = text.slice(i + 3, end);
    const value = body
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l.length)
      .join('\n')
      // A trailing backslash continues the line, so join those without a break.
      .replace(/\\\n/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    return [value, end + 3];
  }
  if (text[i] !== '"') return [null, i];
  let out = '';
  let j = i + 1;
  while (j < text.length) {
    const c = text[j];
    if (c === '\\') {
      out += text[j + 1];
      j += 2;
      continue;
    }
    if (c === '"') return [out, j + 1];
    out += c;
    j += 1;
  }
  return [out, j];
}

/** Collects every string literal inside a balanced (...) or [...] span. */
function stringsIn(text, start, open, close) {
  let depth = 0;
  let i = start;
  const found = [];
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      const [value, next] = readString(text, i);
      if (value !== null) found.push(value);
      i = next;
      continue;
    }
    if (c === open) depth += 1;
    else if (c === close) {
      depth -= 1;
      if (depth === 0) return [found, i + 1];
    }
    i += 1;
  }
  return [found, i];
}

/** Parses one topic's `blocks: [...]` into structured blocks. */
function parseBlocks(text, start) {
  const blocks = [];
  let depth = 0;
  let i = start;
  while (i < text.length) {
    const c = text[i];
    if (c === '[') depth += 1;
    else if (c === ']') {
      depth -= 1;
      if (depth === 0) return blocks;
    } else if (c === '.' && depth === 1) {
      const kind = /^\.(text|heading|bullets|steps|table|tip)\b/.exec(text.slice(i));
      if (kind) {
        const type = kind[1];
        let j = i + kind[0].length;
        while (text[j] === ' ' || text[j] === '\n') j += 1;
        if (type === 'text' || type === 'heading' || type === 'tip') {
          const [, afterParen] = [text[j], j + 1];
          const [value, next] = readString(text, afterParen);
          blocks.push({ type, value });
          i = next;
          continue;
        }
        if (type === 'bullets' || type === 'steps') {
          const [items, next] = stringsIn(text, j, '(', ')');
          blocks.push({ type, items });
          i = next;
          continue;
        }
        if (type === 'table') {
          const [cells, next] = stringsIn(text, j, '(', ')');
          const rows = [];
          for (let k = 0; k + 1 < cells.length; k += 2) rows.push([cells[k], cells[k + 1]]);
          blocks.push({ type, rows });
          i = next;
          continue;
        }
      }
    }
    i += 1;
  }
  return blocks;
}

// --- topics -----------------------------------------------------------------

const topics = new Map();
const topicRe =
  /static let (\w+) = HelpTopic\(\s*id: "([^"]+)",\s*title: "([^"]*)",\s*summary: "([^"]*)",\s*symbol: "([^"]*)",\s*keywords: "([^"]*)",\s*blocks: \[/g;

for (const m of swift.matchAll(topicRe)) {
  const [full, varName, id, title, summary, symbol, keywords] = m;
  const blocksStart = swift.indexOf('[', m.index + full.length - 1);
  topics.set(varName, {
    id,
    title,
    summary,
    symbol,
    keywords,
    blocks: parseBlocks(swift, blocksStart),
  });
}

// --- sections, in the order the app presents them ---------------------------

const sections = [];
const sectionRe = /HelpSection\(id: "([^"]+)", title: "([^"]*)", topics: \[([^\]]*)\]/g;
for (const m of swift.matchAll(sectionRe)) {
  const [, id, title, list] = m;
  const members = list
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((name) => topics.get(name))
    .filter(Boolean);
  sections.push({ id, title, topics: members });
}

if (!sections.length || !topics.size) {
  console.error('No help content parsed — has HelpContent.swift changed shape?');
  process.exit(1);
}

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify({ sections }, null, 2) + '\n');

const count = sections.reduce((n, s) => n + s.topics.length, 0);
console.log(`manual.json — ${sections.length} sections, ${count} topics`);
for (const s of sections) console.log(`  ${s.title}: ${s.topics.map((t) => t.id).join(', ')}`);
