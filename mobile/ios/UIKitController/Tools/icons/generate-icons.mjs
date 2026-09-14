#!/usr/bin/env node
// Converts the Lucide icons listed in icons.txt into native CoreGraphics
// geometry: App/DesignSystem/Icons/RCIconPaths.generated.swift.
//
// Usage:
//   node generate-icons.mjs [lucide-icons-dir] [--list <icons.txt>] [--out <file.swift>] [--check]
//
// lucide-icons-dir defaults to <repo>/web/node_modules/lucide-react/dist/esm/icons.
// --check writes nothing and exits 1 when the generated file is out of date.
//
// Dependency-free (Node 18+). Icon modules are parsed as text, never imported.
// Every SVG element is lowered to absolute move/line/cubic/quad/close commands
// following SVG 2 geometry rules; elliptical arcs become cubic Béziers of at
// most 90° each. Anything unsupported fails the run with a non-zero exit code.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));

class GenError extends Error {}
const fail = (message) => {
  throw new GenError(message);
};

// ---------------------------------------------------------------------------
// Command line

function parseArgs(argv) {
  const options = {
    iconsDir: resolve(scriptDir, '../../../../../web/node_modules/lucide-react/dist/esm/icons'),
    list: join(scriptDir, 'icons.txt'),
    out: resolve(scriptDir, '../../App/DesignSystem/Icons/RCIconPaths.generated.swift'),
    check: false,
  };
  let positional = 0;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) fail(`${arg} needs a value`);
      return argv[++i];
    };
    if (arg === '--list') options.list = resolve(value());
    else if (arg === '--out') options.out = resolve(value());
    else if (arg === '--check') options.check = true;
    else if (arg === '-h' || arg === '--help') {
      process.stdout.write(
        'usage: node generate-icons.mjs [lucide-icons-dir] [--list icons.txt] [--out file.swift] [--check]\n',
      );
      process.exit(0);
    } else if (arg.startsWith('-')) fail(`unknown option ${arg}`);
    else if (positional++ === 0) options.iconsDir = resolve(arg);
    else fail(`unexpected argument ${arg}`);
  }
  return options;
}

// ---------------------------------------------------------------------------
// icons.txt

function readIconList(file) {
  if (!existsSync(file)) fail(`icon list not found: ${file}`);
  const entries = [];
  const seen = new Set();
  readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .forEach((raw, index) => {
      const line = raw.replace(/#.*$/, '').trim();
      if (!line) return;
      const optional = line.startsWith('?');
      const name = optional ? line.slice(1).trim() : line;
      if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) {
        fail(`${file}:${index + 1}: invalid Lucide icon name '${line}'`);
      }
      if (seen.has(name)) fail(`${file}:${index + 1}: duplicate icon '${name}'`);
      seen.add(name);
      entries.push({ name, optional });
    });
  if (entries.length === 0) fail(`${file} lists no icons`);
  return entries;
}

// ---------------------------------------------------------------------------
// Icon module source: createLucideIcon("Name", [[tag, {attrs}], ...])

function loadIcon(iconsDir, name) {
  let current = name;
  for (let depth = 0; depth < 8; depth++) {
    const file = join(iconsDir, `${current}.js`);
    if (!existsSync(file)) return null;
    const source = readFileSync(file, 'utf8');
    const call = /\bcreateLucideIcon\s*\(/g;
    const match = call.exec(source);
    if (!match) {
      // Deprecated names are re-exports: export { default } from './circle-alert.js';
      const alias = /export\s*\{\s*default\s*\}\s*from\s*['"]\.\/([a-z0-9-]+)\.js['"]/.exec(source);
      if (!alias) fail(`${file}: no createLucideIcon(...) call or alias re-export`);
      current = alias[1];
      continue;
    }
    if (call.exec(source)) fail(`${file}: more than one createLucideIcon(...) call`);
    const reader = new LiteralReader(source, match.index + match[0].length, file);
    const displayName = reader.value();
    reader.expect(',');
    const nodes = reader.value();
    reader.optional(',');
    reader.expect(')');
    if (typeof displayName !== 'string') fail(`${file}: icon name is not a string`);
    if (!Array.isArray(nodes)) fail(`${file}: icon node list is not an array`);
    const version = /@license\s+lucide-react\s+v(\S+)/.exec(source)?.[1] ?? null;
    return { file, nodes, version };
  }
  fail(`${name}: alias chain is too deep`);
}

/** Reads JSON-like JavaScript literals (arrays, objects, strings, numbers). */
class LiteralReader {
  constructor(text, pos, file) {
    this.text = text;
    this.pos = pos;
    this.file = file;
  }

  error(message) {
    const line = this.text.slice(0, this.pos).split('\n').length;
    fail(`${this.file}:${line}: ${message}`);
  }

  skip() {
    for (;;) {
      const rest = this.text.slice(this.pos);
      const ws = /^(?:\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/)/.exec(rest);
      if (!ws) return;
      this.pos += ws[0].length;
    }
  }

  peek() {
    this.skip();
    return this.text[this.pos];
  }

  optional(ch) {
    if (this.peek() !== ch) return false;
    this.pos++;
    return true;
  }

  expect(ch) {
    if (!this.optional(ch)) this.error(`expected '${ch}'`);
  }

  value() {
    const ch = this.peek();
    if (ch === '[') return this.array();
    if (ch === '{') return this.object();
    if (ch === '"' || ch === "'") return this.string();
    const rest = this.text.slice(this.pos);
    const number = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/.exec(rest);
    if (number) {
      this.pos += number[0].length;
      return Number(number[0]);
    }
    const word = /^(?:true|false|null)\b/.exec(rest);
    if (word) {
      this.pos += word[0].length;
      return JSON.parse(word[0]);
    }
    this.error(`unsupported literal starting with '${rest.slice(0, 16)}'`);
  }

  array() {
    this.expect('[');
    const items = [];
    while (!this.optional(']')) {
      items.push(this.value());
      if (!this.optional(',')) {
        this.expect(']');
        break;
      }
    }
    return items;
  }

  object() {
    this.expect('{');
    const result = {};
    while (!this.optional('}')) {
      let key;
      const ch = this.peek();
      if (ch === '"' || ch === "'") key = this.string();
      else {
        const ident = /^[A-Za-z_$][\w$]*/.exec(this.text.slice(this.pos));
        if (!ident) this.error('expected object key');
        key = ident[0];
        this.pos += key.length;
      }
      this.expect(':');
      if (Object.hasOwn(result, key)) this.error(`duplicate key '${key}'`);
      result[key] = this.value();
      if (!this.optional(',')) {
        this.expect('}');
        break;
      }
    }
    return result;
  }

  string() {
    const quote = this.text[this.pos++];
    let out = '';
    for (;;) {
      if (this.pos >= this.text.length) this.error('unterminated string');
      const ch = this.text[this.pos++];
      if (ch === quote) return out;
      if (ch === '\n') this.error('newline in string');
      if (ch !== '\\') {
        out += ch;
        continue;
      }
      const esc = this.text[this.pos++];
      const simple = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', 0: '\0' };
      if (esc in simple) out += simple[esc];
      else if (esc === 'x' || esc === 'u') {
        const hex = esc === 'x' ? /^[0-9a-fA-F]{2}/ : /^[0-9a-fA-F]{4}/;
        const digits = hex.exec(this.text.slice(this.pos));
        if (!digits) this.error(`bad \\${esc} escape`);
        this.pos += digits[0].length;
        out += String.fromCharCode(parseInt(digits[0], 16));
      } else out += esc;
    }
  }
}

// ---------------------------------------------------------------------------
// Geometry. Segments are absolute: M x y | L x y | C x1 y1 x2 y2 x y | Q x1 y1 x y | Z

const NUMBER = /[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/y;

function parseNumberAttr(value, what) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string') fail(`${what}: expected a number, got ${JSON.stringify(value)}`);
  const trimmed = value.trim();
  NUMBER.lastIndex = 0;
  const match = NUMBER.exec(trimmed);
  if (!match || match[0].length !== trimmed.length) {
    fail(`${what}: unsupported value ${JSON.stringify(value)} (units and percentages are not supported)`);
  }
  return Number(match[0]);
}

/** Endpoint-parameterized elliptical arc to cubic Béziers (SVG 2 implementation notes B.2.4/B.2.5). */
function arcToCubics(x1, y1, rxIn, ryIn, angleDeg, largeArc, sweep, x2, y2) {
  if (x1 === x2 && y1 === y2) return []; // Arc with identical endpoints is omitted.
  let rx = Math.abs(rxIn);
  let ry = Math.abs(ryIn);
  if (rx === 0 || ry === 0) return [['L', x2, y2]];

  const phi = (((angleDeg % 360) + 360) % 360) * (Math.PI / 180);
  const cosPhi = Math.cos(phi);
  const sinPhi = Math.sin(phi);
  const hx = (x1 - x2) / 2;
  const hy = (y1 - y2) / 2;
  const x1p = cosPhi * hx + sinPhi * hy;
  const y1p = -sinPhi * hx + cosPhi * hy;

  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    const s = Math.sqrt(lambda);
    rx *= s;
    ry *= s;
  }
  const rx2 = rx * rx;
  const ry2 = ry * ry;
  const numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
  const denominator = rx2 * y1p * y1p + ry2 * x1p * x1p;
  let k = Math.sqrt(Math.max(0, numerator / denominator));
  if (largeArc === sweep) k = -k;
  const cxp = (k * rx * y1p) / ry;
  const cyp = (-k * ry * x1p) / rx;
  const cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
  const cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;

  const angle = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
  const ux = (x1p - cxp) / rx;
  const uy = (y1p - cyp) / ry;
  const vx = (-x1p - cxp) / rx;
  const vy = (-y1p - cyp) / ry;
  const theta1 = angle(1, 0, ux, uy);
  let delta = angle(ux, uy, vx, vy);
  if (!sweep && delta > 0) delta -= 2 * Math.PI;
  else if (sweep && delta < 0) delta += 2 * Math.PI;

  const count = Math.max(1, Math.ceil(Math.abs(delta) / (Math.PI / 2) - 1e-9));
  const step = delta / count;
  const t = (4 / 3) * Math.tan(step / 4);
  const map = (ex, ey) => [cx + rx * ex * cosPhi - ry * ey * sinPhi, cy + rx * ex * sinPhi + ry * ey * cosPhi];

  const segments = [];
  for (let i = 0; i < count; i++) {
    const a1 = theta1 + i * step;
    const a2 = a1 + step;
    const [c1x, c1y] = map(Math.cos(a1) - t * Math.sin(a1), Math.sin(a1) + t * Math.cos(a1));
    const [c2x, c2y] = map(Math.cos(a2) + t * Math.sin(a2), Math.sin(a2) - t * Math.cos(a2));
    const [ex, ey] = i === count - 1 ? [x2, y2] : map(Math.cos(a2), Math.sin(a2));
    segments.push(['C', c1x, c1y, c2x, c2y, ex, ey]);
  }
  return segments;
}

const ARG_COUNT = { M: 2, L: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, T: 2, A: 7, Z: 0 };

/** Parses SVG path data into absolute segments. */
function parsePathData(d, what) {
  const out = [];
  let pos = 0;
  const err = (message) => fail(`${what}: path data ${message} at offset ${pos}: ${JSON.stringify(d)}`);
  const skipWsp = () => {
    while (pos < d.length && ' \t\r\n\f'.includes(d[pos])) pos++;
  };
  const skipCommaWsp = () => {
    skipWsp();
    if (d[pos] === ',') {
      pos++;
      skipWsp();
    }
  };
  const readNumber = () => {
    NUMBER.lastIndex = pos;
    const match = NUMBER.exec(d);
    if (!match) err('expected a number');
    pos += match[0].length;
    return Number(match[0]);
  };
  const readFlag = () => {
    const ch = d[pos];
    if (ch !== '0' && ch !== '1') err('expected an arc flag (0 or 1)');
    pos++;
    return ch === '1';
  };

  let x = 0; // current point
  let y = 0;
  let startX = 0; // current subpath start
  let startY = 0;
  let cubicCtrl = null; // last C/S second control point, for S reflection
  let quadCtrl = null; // last Q/T control point, for T reflection
  let pendingMove = false; // after Z, the next drawing command starts a new subpath
  let first = true;

  for (;;) {
    skipWsp();
    if (pos >= d.length) break;
    const letter = d[pos];
    const upper = letter.toUpperCase();
    if (!(upper in ARG_COUNT) || !/[A-Za-z]/.test(letter)) err(`has unsupported command '${letter}'`);
    if (first && upper !== 'M') err('must start with a moveto');
    first = false;
    pos++;
    const relative = letter !== upper;

    if (upper === 'Z') {
      out.push(['Z']);
      x = startX;
      y = startY;
      cubicCtrl = null;
      quadCtrl = null;
      pendingMove = true;
      continue;
    }

    let command = upper;
    for (;;) {
      skipWsp();
      const a = [];
      for (let i = 0; i < ARG_COUNT[command]; i++) {
        if (i > 0) skipCommaWsp();
        a.push(command === 'A' && (i === 3 || i === 4) ? readFlag() : readNumber());
      }
      if (pendingMove && command !== 'M') {
        // Drawing right after Z starts a new subpath at the closed subpath's start point.
        out.push(['M', x, y]);
        pendingMove = false;
      }
      const ox = relative ? x : 0;
      const oy = relative ? y : 0;
      let nextCubic = null;
      let nextQuad = null;

      switch (command) {
        case 'M':
          x = a[0] + ox;
          y = a[1] + oy;
          startX = x;
          startY = y;
          pendingMove = false;
          out.push(['M', x, y]);
          command = 'L'; // Extra coordinate pairs are implicit linetos.
          break;
        case 'L':
          x = a[0] + ox;
          y = a[1] + oy;
          out.push(['L', x, y]);
          break;
        case 'H':
          x = a[0] + ox;
          out.push(['L', x, y]);
          break;
        case 'V':
          y = a[0] + oy;
          out.push(['L', x, y]);
          break;
        case 'C': {
          const seg = ['C', a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy, a[4] + ox, a[5] + oy];
          out.push(seg);
          nextCubic = [seg[3], seg[4]];
          [x, y] = [seg[5], seg[6]];
          break;
        }
        case 'S': {
          const [c1x, c1y] = cubicCtrl ? [2 * x - cubicCtrl[0], 2 * y - cubicCtrl[1]] : [x, y];
          const seg = ['C', c1x, c1y, a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy];
          out.push(seg);
          nextCubic = [seg[3], seg[4]];
          [x, y] = [seg[5], seg[6]];
          break;
        }
        case 'Q': {
          const seg = ['Q', a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy];
          out.push(seg);
          nextQuad = [seg[1], seg[2]];
          [x, y] = [seg[3], seg[4]];
          break;
        }
        case 'T': {
          const [cx, cy] = quadCtrl ? [2 * x - quadCtrl[0], 2 * y - quadCtrl[1]] : [x, y];
          const seg = ['Q', cx, cy, a[0] + ox, a[1] + oy];
          out.push(seg);
          nextQuad = [cx, cy];
          [x, y] = [seg[3], seg[4]];
          break;
        }
        case 'A': {
          const ex = a[5] + ox;
          const ey = a[6] + oy;
          for (const seg of arcToCubics(x, y, a[0], a[1], a[2], a[3], a[4], ex, ey)) out.push(seg);
          [x, y] = [ex, ey];
          break;
        }
      }
      cubicCtrl = nextCubic;
      quadCtrl = nextQuad;

      skipWsp();
      if (d[pos] === ',') {
        pos++;
        skipWsp();
        if (!/[0-9+\-.]/.test(d[pos] ?? '')) err('has a dangling comma');
      } else if (!/[0-9+\-.]/.test(d[pos] ?? '')) {
        break;
      }
    }
  }
  return out;
}

const ALLOWED_ATTRS = {
  path: ['d'],
  circle: ['cx', 'cy', 'r'],
  ellipse: ['cx', 'cy', 'rx', 'ry'],
  rect: ['x', 'y', 'width', 'height', 'rx', 'ry'],
  line: ['x1', 'y1', 'x2', 'y2'],
  polyline: ['points'],
  polygon: ['points'],
};

function ellipseSegments(cx, cy, rx, ry) {
  // SVG 2: start at (cx+rx, cy) and sweep through the four quadrants.
  const points = [
    [cx + rx, cy],
    [cx, cy + ry],
    [cx - rx, cy],
    [cx, cy - ry],
    [cx + rx, cy],
  ];
  const out = [['M', ...points[0]]];
  for (let i = 1; i < points.length; i++) {
    out.push(...arcToCubics(...points[i - 1], rx, ry, 0, false, true, ...points[i]));
  }
  out.push(['Z']);
  return out;
}

function parsePoints(value, what) {
  if (typeof value !== 'string') fail(`${what}: points must be a string`);
  const numbers = [];
  let pos = 0;
  const skip = () => {
    while (pos < value.length && /[\s,]/.test(value[pos])) pos++;
  };
  for (skip(); pos < value.length; skip()) {
    NUMBER.lastIndex = pos;
    const match = NUMBER.exec(value);
    if (!match) fail(`${what}: invalid points ${JSON.stringify(value)}`);
    numbers.push(Number(match[0]));
    pos += match[0].length;
  }
  if (numbers.length % 2 !== 0) fail(`${what}: odd number of coordinates in points`);
  const pairs = [];
  for (let i = 0; i < numbers.length; i += 2) pairs.push([numbers[i], numbers[i + 1]]);
  return pairs;
}

/** Lowers one Lucide icon node to absolute segments. */
function elementSegments(tag, attrs, what) {
  if (!Object.hasOwn(ALLOWED_ATTRS, tag)) fail(`${what}: unsupported element <${tag}>`);
  if (attrs === null || typeof attrs !== 'object' || Array.isArray(attrs)) fail(`${what}: attributes must be an object`);
  for (const name of Object.keys(attrs)) {
    if (name === 'key' || name === 'fill') continue;
    if (!ALLOWED_ATTRS[tag].includes(name)) fail(`${what}: unsupported attribute ${name} on <${tag}>`);
  }
  const num = (name, fallback) =>
    attrs[name] === undefined ? fallback : parseNumberAttr(attrs[name], `${what} <${tag}> ${name}`);
  const nonNegative = (name, fallback) => {
    const value = num(name, fallback);
    if (value !== undefined && value < 0) fail(`${what}: negative ${name} on <${tag}>`);
    return value;
  };

  // The renderer only strokes. Lucide fills nothing but small "dot" circles
  // (fill="currentColor", r = .5), whose SVG rendering is a solid disc.
  const filledDot = attrs.fill !== undefined && attrs.fill !== 'none';
  if (filledDot && (attrs.fill !== 'currentColor' || tag !== 'circle' || nonNegative('r', 0) > 1)) {
    fail(`${what}: fill=${JSON.stringify(attrs.fill)} on <${tag}> is not supported (stroke-only renderer)`);
  }

  switch (tag) {
    case 'path': {
      if (typeof attrs.d !== 'string') fail(`${what}: <path> without d`);
      return parsePathData(attrs.d, what);
    }
    case 'circle': {
      const r = nonNegative('r', 0);
      const cx = num('cx', 0);
      const cy = num('cy', 0);
      const ring = r === 0 ? [] : ellipseSegments(cx, cy, r, r);
      if (!filledDot) return ring;
      // CoreGraphics strokes a circle whose radius is below half the line width
      // with a pinhole of radius (width/2 - r). A round-capped .01 dash at the
      // center covers it, keeping the disc solid for any stroke width >= r.
      return [...ring, ['M', cx - 0.005, cy], ['L', cx + 0.005, cy]];
    }
    case 'ellipse': {
      let rx = nonNegative('rx', undefined);
      let ry = nonNegative('ry', undefined);
      rx ??= ry ?? 0; // SVG 2 "auto": use the other radius.
      ry ??= rx;
      return rx === 0 || ry === 0 ? [] : ellipseSegments(num('cx', 0), num('cy', 0), rx, ry);
    }
    case 'rect': {
      const x = num('x', 0);
      const y = num('y', 0);
      const w = nonNegative('width', 0);
      const h = nonNegative('height', 0);
      if (w === 0 || h === 0) return [];
      let rx = nonNegative('rx', undefined);
      let ry = nonNegative('ry', undefined);
      rx ??= ry ?? 0;
      ry ??= rx;
      rx = Math.min(rx, w / 2);
      ry = Math.min(ry, h / 2);
      if (rx === 0 || ry === 0) {
        return [['M', x, y], ['L', x + w, y], ['L', x + w, y + h], ['L', x, y + h], ['Z']];
      }
      // SVG 2 rounded rectangle outline, clockwise from the top edge.
      const out = [['M', x + rx, y]];
      let [lastX, lastY] = [x + rx, y];
      const edge = (px, py) => {
        // A zero-length edge (radius = half the side) draws nothing inside a closed outline.
        if (px !== lastX || py !== lastY) out.push(['L', px, py]);
        [lastX, lastY] = [px, py];
      };
      const corner = (px, py) => {
        out.push(...arcToCubics(lastX, lastY, rx, ry, 0, false, true, px, py));
        [lastX, lastY] = [px, py];
      };
      edge(x + w - rx, y);
      corner(x + w, y + ry);
      edge(x + w, y + h - ry);
      corner(x + w - rx, y + h);
      edge(x + rx, y + h);
      corner(x, y + h - ry);
      edge(x, y + ry);
      corner(x + rx, y);
      out.push(['Z']);
      return out;
    }
    case 'line':
      return [
        ['M', num('x1', 0), num('y1', 0)],
        ['L', num('x2', 0), num('y2', 0)],
      ];
    case 'polyline':
    case 'polygon': {
      const pairs = parsePoints(attrs.points, what);
      if (pairs.length === 0) return [];
      const out = pairs.map(([px, py], i) => [i === 0 ? 'M' : 'L', px, py]);
      if (tag === 'polygon') out.push(['Z']);
      return out;
    }
  }
  return fail(`${what}: unreachable element <${tag}>`);
}

// ---------------------------------------------------------------------------
// Swift emission

// Keywords reserved in declarations, statements, expressions and types (The Swift
// Programming Language, "Lexical Structure"), plus declaration modifiers that are
// safest escaped. Escaped cases keep their name: call sites still write `.repeat`.
const SWIFT_KEYWORDS = new Set(
  (
    'associatedtype borrowing class consuming deinit enum extension fileprivate func import init inout ' +
    'internal let nonisolated open operator package private precedencegroup protocol public rethrows ' +
    'static struct subscript typealias var ' +
    'break case catch continue default defer do else fallthrough for guard if in repeat return throw ' +
    'switch where while ' +
    'Any as await false is nil self Self super throws true try'
  ).split(' '),
);

function swiftCaseName(name) {
  const parts = name.split('-');
  const camel = parts[0] + parts.slice(1).map((p) => p[0].toUpperCase() + p.slice(1)).join('');
  if (!/^[a-z][A-Za-z0-9]*$/.test(camel)) fail(`cannot derive a Swift case name from '${name}'`);
  // `.none`/`.some` on an `RCIconGlyph?` would be ambiguous with Optional's cases.
  if (camel === 'none' || camel === 'some') fail(`'${name}' would shadow Optional.${camel}; rename it`);
  return camel;
}

const escapeCase = (name) => (SWIFT_KEYWORDS.has(name) ? `\`${name}\`` : name);

function formatNumber(value) {
  if (!Number.isFinite(value)) fail(`non-finite coordinate ${value}`);
  let rounded = Math.round(value * 1e4) / 1e4;
  if (Object.is(rounded, -0)) rounded = 0;
  const text = String(rounded);
  return /e/i.test(text) ? rounded.toFixed(4).replace(/\.?0+$/, '') : text;
}

function emitCalls(segments) {
  return segments.map((segment) => {
    const [op, ...coords] = segment;
    const args = coords.map(formatNumber).join(', ');
    switch (op) {
      case 'M':
        return `p.move(${args})`;
      case 'L':
        return `p.line(${args})`;
      case 'C':
        return `p.curve(${args})`;
      case 'Q':
        return `p.quad(${args})`;
      case 'Z':
        return 'p.close()';
    }
    return fail(`unknown segment ${op}`);
  });
}

function wrapCalls(calls, indent, width = 120) {
  const lines = [];
  let line = '';
  for (const call of calls) {
    const piece = `${call};`;
    if (line && indent.length + line.length + 1 + piece.length > width) {
      lines.push(indent + line);
      line = piece;
    } else {
      line = line ? `${line} ${piece}` : piece;
    }
  }
  if (line) lines.push(indent + line);
  return lines;
}

function emitSwift(glyphs, version) {
  const out = [];
  out.push('// Generated by Tools/icons/generate-icons.mjs. Do not edit.');
  out.push('//');
  out.push(`// Geometry derived from Lucide icons (lucide-react ${version}, https://lucide.dev),`);
  out.push('// ISC License. See THIRD_PARTY_NOTICES.md for the full license notice.');
  out.push('');
  out.push('import CoreGraphics');
  out.push('');
  out.push('/// Lucide glyphs used by the app. Raw value = Lucide icon name.');
  out.push('enum RCIconGlyph: String, CaseIterable, Sendable {');
  for (const glyph of glyphs) out.push(`    case ${escapeCase(glyph.caseName)} = "${glyph.name}"`);
  out.push('}');
  out.push('');
  out.push('extension RCIconGlyph {');
  out.push("    /// Stroke geometry in Lucide's 24×24 viewBox (y down, UIKit orientation).");
  out.push('    func makePath() -> CGPath {');
  out.push('        let p = RCIconPathBuilder()');
  out.push('        switch self {');
  for (const glyph of glyphs) {
    out.push(`        case .${escapeCase(glyph.caseName)}:`);
    for (const element of glyph.elements) out.push(...wrapCalls(emitCalls(element), '            '));
  }
  out.push('        }');
  out.push('        return p.finish()');
  out.push('    }');
  out.push('}');
  out.push('');
  out.push('private struct RCIconPathBuilder {');
  out.push('    private let path = CGMutablePath()');
  out.push('');
  out.push('    func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: CGPoint(x: x, y: y)) }');
  out.push('    func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: CGPoint(x: x, y: y)) }');
  out.push('    func quad(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) {');
  out.push('        path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))');
  out.push('    }');
  out.push('    func curve(');
  out.push('        _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat');
  out.push('    ) {');
  out.push(
    '        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))',
  );
  out.push('    }');
  out.push('    func close() { path.closeSubpath() }');
  out.push('    func finish() -> CGPath { path.copy() ?? path }');
  out.push('}');
  return `${out.join('\n')}\n`;
}

// ---------------------------------------------------------------------------

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!existsSync(options.iconsDir)) fail(`Lucide icons directory not found: ${options.iconsDir}`);

  const glyphs = [];
  const versions = new Set();
  const skipped = [];
  for (const entry of readIconList(options.list)) {
    const icon = loadIcon(options.iconsDir, entry.name);
    if (!icon) {
      if (entry.optional) {
        skipped.push(entry.name);
        continue;
      }
      fail(`icon '${entry.name}' not found in ${options.iconsDir}`);
    }
    if (!icon.version) fail(`${icon.file}: missing lucide-react license banner`);
    versions.add(icon.version);
    const elements = icon.nodes.map((node, index) => {
      const what = `${entry.name}[${index}]`;
      if (!Array.isArray(node) || node.length < 2 || typeof node[0] !== 'string') fail(`${what}: malformed icon node`);
      if (node.length > 2 && !(Array.isArray(node[2]) && node[2].length === 0)) fail(`${what}: nested children are not supported`);
      return elementSegments(node[0], node[1], what);
    });
    if (!elements.some((segments) => segments.some(([op]) => op !== 'M' && op !== 'Z'))) {
      fail(`${entry.name}: icon produced no drawable geometry`);
    }
    glyphs.push({ name: entry.name, caseName: swiftCaseName(entry.name), elements: elements.filter((e) => e.length) });
  }
  if (versions.size !== 1) fail(`icons come from mixed lucide-react versions: ${[...versions].join(', ')}`);

  glyphs.sort((a, b) => (a.caseName < b.caseName ? -1 : a.caseName > b.caseName ? 1 : 0));
  for (let i = 1; i < glyphs.length; i++) {
    if (glyphs[i].caseName === glyphs[i - 1].caseName) {
      fail(`'${glyphs[i - 1].name}' and '${glyphs[i].name}' map to the same Swift case`);
    }
  }

  const swift = emitSwift(glyphs, [...versions][0]);
  const shownOut = relative(process.cwd(), options.out) || options.out;
  for (const name of skipped) process.stderr.write(`note: optional icon '${name}' is not in lucide-react; skipped\n`);
  if (options.check) {
    const current = existsSync(options.out) ? readFileSync(options.out, 'utf8') : null;
    if (current !== swift) fail(`${shownOut} is out of date; run generate-icons.mjs`);
    process.stderr.write(`${shownOut} is up to date (${glyphs.length} glyphs)\n`);
    return;
  }
  mkdirSync(dirname(options.out), { recursive: true });
  writeFileSync(options.out, swift);
  process.stderr.write(`wrote ${glyphs.length} glyphs to ${shownOut}\n`);
}

try {
  main();
} catch (error) {
  if (!(error instanceof GenError)) throw error;
  process.stderr.write(`error: ${error.message}\n`);
  process.exit(1);
}
