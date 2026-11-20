// 生成 1024x1024 的 App 图标（纯 Node，无依赖）：深色底 + 绿色圆角块 + 播放三角
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SS = 2;                 // 2x 超采样抗锯齿
const SIZE = 1024;
const N = SIZE * SS;

function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function mix(a, b, t) { return a + (b - a) * t; }

function roundedRectCoverage(x, y, rect, radius) {
  const [x0, y0, x1, y1] = rect;
  const cx = Math.min(Math.max(x, x0 + radius), x1 - radius);
  const cy = Math.min(Math.max(y, y0 + radius), y1 - radius);
  const dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= radius * radius ? 1 : 0;
}

function triangleCoverage(x, y) {
  // 顶点 (430,352) (430,672) (712,512) —— 相对 1024 坐标
  const ax = 430, ay = 352, bx = 430, by = 672, cx = 712, cy = 512;
  const d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by);
  const d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy);
  const d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay);
  const hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  const hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return hasNeg && hasPos ? 0 : 1;
}

const pixels = Buffer.alloc(N * N * 3);

for (let py = 0; py < N; py++) {
  for (let px = 0; px < N; px++) {
    const u = (px + 0.5) / SS;
    const v = (py + 0.5) / SS;

    // 背景：对角深色渐变
    const t = clamp01((u / SIZE) * 0.6 + (v / SIZE) * 0.4);
    let r = mix(9, 18, t);
    let g = mix(14, 42, t);
    let b = mix(20, 32, t);

    // 中心柔光
    const dx = (u - SIZE / 2) / (SIZE * 0.55);
    const dy = (v - SIZE / 2) / (SIZE * 0.55);
    const glow = Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy));
    r += 12 * glow * glow;
    g += 46 * glow * glow;
    b += 30 * glow * glow;

    // 圆角实心块
    if (roundedRectCoverage(u, v, [176, 176, 848, 848], 208)) {
      const gt = clamp01((u - 176) / 672 * 0.7 + (v - 176) / 672 * 0.3);
      r = mix(0x4A, 0x22, gt);
      g = mix(0xDE, 0xD3, gt);
      b = mix(0x80, 0xA8, gt);
      // 块内播放三角（深色挖空）
      if (triangleCoverage(u, v)) {
        r = 10; g = 18; b = 16;
      }
    }

    const index = (py * N + px) * 3;
    pixels[index] = Math.min(255, Math.round(r));
    pixels[index + 1] = Math.min(255, Math.round(g));
    pixels[index + 2] = Math.min(255, Math.round(b));
  }
}

// 降采样
const out = Buffer.alloc(SIZE * SIZE * 3);
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    let r = 0, g = 0, b = 0;
    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        const index = ((y * SS + sy) * N + (x * SS + sx)) * 3;
        r += pixels[index]; g += pixels[index + 1]; b += pixels[index + 2];
      }
    }
    const count = SS * SS;
    const index = (y * SIZE + x) * 3;
    out[index] = Math.round(r / count);
    out[index + 1] = Math.round(g / count);
    out[index + 2] = Math.round(b / count);
  }
}

function chunk(tag, payload) {
  const body = Buffer.concat([tag, payload]);
  const length = Buffer.alloc(4); length.writeUInt32BE(payload.length, 0);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(body) >>> 0, 0);
  return Buffer.concat([length, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 3 + 1)] = 0;
  out.copy(raw, y * (SIZE * 3 + 1) + 1, y * SIZE * 3, (y + 1) * SIZE * 3);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk(Buffer.from('IHDR'), ihdr),
  chunk(Buffer.from('IDAT'), zlib.deflateSync(raw, { level: 9 })),
  chunk(Buffer.from('IEND'), Buffer.alloc(0)),
]);

const target = path.join(__dirname, '..', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset');
fs.mkdirSync(target, { recursive: true });
fs.writeFileSync(path.join(target, 'icon-1024.png'), png);
console.log('icon-1024.png', png.length, 'bytes ->', target);
