#!/usr/bin/env node
/**
 * 生成应用图标（Android 各密度 + Android 自适应图标 + Web/PWA + favicon）。
 *
 * ## 为什么是一个脚本，而不是一堆二进制
 *
 * 「图标」这件事在工程上有两个容易出事的地方：
 *
 * 1. **每个平台要的文件名、尺寸、留白规则都不同** —— Android 要 5 个密度的
 *    `ic_launcher.png`（48/72/96/144/192），API 26+ 还要一套 `anydpi-v26` 的
 *    自适应图标（前景 108dp 画布，**内容只能占中间 66%**，否则会被启动器裁掉
 *    一圈）；Web/PWA 要 192/512 两份普通图标加两份 `maskable`（同理要留白）。
 *    手工导图必然漏掉其中一两个，而漏掉的症状是**安静**的：
 *    Android 上图标被莫名其妙裁掉一圈、或者 PWA 装到桌面后图标是个小方块。
 * 2. **矢量稿改一次就得重导一遍全部尺寸**。把「画什么」固化成代码之后，
 *    改配色或改图形只改本文件顶部那几个常量，重跑一次即可。
 *
 * 所以这里用纯 Node（只用内置 `zlib`）把图标**当场光栅化**：
 * 不依赖 ImageMagick / PIL / `flutter_launcher_icons`（后者要联网 `pub get`）。
 * 每个尺寸都**按目标分辨率原生绘制 + 4× 超采样**，而不是从一张大图缩下来 ——
 * 缩图会让 48px 那份糊成一团。
 *
 * ## 用法
 *
 * ```bash
 * node tools/make-app-icon.mjs            # 生成全部图标
 * node tools/make-app-icon.mjs --check    # 只检查文件在不在、尺寸对不对（CI/验收用）
 * node tools/make-app-icon.mjs --palette local --android-only   # 本机版配色，只动安卓
 * ```
 *
 * ⚠️ `--palette local` 会**直接覆盖**仓库里的图标文件。要留着云版图标，
 *    调用方必须自己备份/还原 —— `tools/build-local-apk.mjs` 就是这么做的。
 *
 * ## 换成美术给的图时
 *
 * 如果之后有了真设计稿，两条路：
 *   · 用 `flutter_launcher_icons` 按设计稿批量替换（要联网装包）；
 *   · 或把下面的 `drawGlyph()` 换成读取设计稿 PNG 并按平台规则缩放。
 * 无论走哪条，**都要保证 `--check` 通过**（文件名/尺寸/留白是平台规则，不是偏好）。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

// ===== 品牌（改这里即可换配色）=====
//
// 为什么是两套而不是一套：本机后台版与云服务版会**同时装在一台手机上对比**，
// 图标长得一样就没法在桌面上一眼分出来 —— 而「点错了包、去排查网络」是最贵的误判。
// `default` 取自 `lib/constants/app_colors.dart`：primary #4D7CFE / primaryDark #2F5DEB。
// 图标比界面背景小得多，所以梯度拉得比 UI 更开一点，缩到 48px 才有层次。
const PALETTES = {
  default: {
    label: '云端版（蓝）',
    top: [0x5c, 0x8c, 0xff],
    bottom: [0x2e, 0x5b, 0xe8],
    brand: '#4D7CFE',
  },
  local: {
    label: '本机版（绿）',
    top: [0x3a, 0xd9, 0xa0],
    bottom: [0x0a, 0x86, 0x5f],
    brand: '#0E9468',
  },
};

const paletteName = (() => {
  const eq = process.argv.find((a) => a.startsWith('--palette='));
  if (eq) return eq.slice('--palette='.length);
  const i = process.argv.indexOf('--palette');
  return i >= 0 ? process.argv[i + 1] : 'default';
})();
const PALETTE = PALETTES[paletteName];
if (!PALETTE) {
  console.error(`✗ 未知配色 ${paletteName}，可选：${Object.keys(PALETTES).join(' / ')}`);
  process.exit(2);
}

const GRADIENT_TOP = PALETTE.top;
const GRADIENT_BOTTOM = PALETTE.bottom;
/** 图标主色，写进 `web/manifest.json` 的 theme_color 与 Android 自适应图标背景。 */
export const BRAND_COLOR = PALETTE.brand;

/** 只生成安卓要的那几张（构建本地包时用，避免顺带改掉 web 图标）。 */
const ANDROID_ONLY = process.argv.includes('--android-only');

/** 超采样倍数。4× 已经能给 16 级边缘灰阶，肉眼看不出锯齿。 */
const SS = 4;

// ===== 图形：一本摊开的书 =====
//
// 两片「书页」各是一个四边形：**外侧高、书脊处矮**，于是上缘从书脊向两侧
// 往上扬、下缘向两侧往下沉 —— 页面向外张开，这是「摊开的书」的剪影。
//
// ⚠️ 反过来画（书脊高、外侧矮）得到的是**一个立方体的角**，不是书 ——
// 第一版就是这么写反的，45–192px 全渲染成了「一个白色的方块转角」，
// 拿 `web/icons/Icon-512.png` 看一眼才发现。**这类几何错误代码不会报错。**
//
// 坐标是**字形盒内的归一化坐标**（0..1），与画布尺寸无关。
const PAGE_LEFT = [
  [0.494, 0.22],
  [0.03, 0.10],
  [0.03, 0.90],
  [0.494, 0.78],
];
const PAGE_RIGHT = [
  [0.506, 0.22],
  [0.97, 0.10],
  [0.97, 0.90],
  [0.506, 0.78],
];
/**
 * 字形盒的宽高比。书比正方形扁，直接按正方形放会把上下顶到边。
 * 0.82 = 字形在竖向上占的比例，剩下的是上下留白。
 */
const GLYPH_ASPECT = 0.82;

// ===== 目标清单 =====
//
// `glyph` = 字形宽度占画布宽度的比例。这个值不是审美参数，是**平台规则**：
// 自适应图标与 maskable 图标会被启动器按各自的形状裁切，内容超出中间那个
// 安全区就会被切掉（表现为「图标缺了个角」或「书本被啃掉一半」）。
const TARGETS = [
  // Android 传统图标：全出血，启动器自己会加圆角/圆形遮罩。
  { path: 'android/app/src/main/res/mipmap-mdpi/ic_launcher.png', size: 48, style: 'legacy', glyph: 0.62 },
  { path: 'android/app/src/main/res/mipmap-hdpi/ic_launcher.png', size: 72, style: 'legacy', glyph: 0.62 },
  { path: 'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png', size: 96, style: 'legacy', glyph: 0.62 },
  { path: 'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png', size: 144, style: 'legacy', glyph: 0.62 },
  { path: 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', size: 192, style: 'legacy', glyph: 0.62 },

  // Android 自适应图标（API 26+）的**前景层**：108dp 画布，中心 66% 是安全区。
  // 背景层不用图，用 colors.xml 里的纯色（见文件末尾），这样启动器做视差时不会露边。
  { path: 'android/app/src/main/res/mipmap-mdpi/ic_launcher_foreground.png', size: 108, style: 'foreground', glyph: 0.44 },
  { path: 'android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png', size: 162, style: 'foreground', glyph: 0.44 },
  { path: 'android/app/src/main/res/mipmap-xhdpi/ic_launcher_foreground.png', size: 216, style: 'foreground', glyph: 0.44 },
  { path: 'android/app/src/main/res/mipmap-xxhdpi/ic_launcher_foreground.png', size: 324, style: 'foreground', glyph: 0.44 },
  { path: 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png', size: 432, style: 'foreground', glyph: 0.44 },

  // Web / PWA。普通图标自己带圆角（浏览器不裁），maskable 必须全出血 + 留白。
  { path: 'web/icons/Icon-192.png', size: 192, style: 'rounded', glyph: 0.62, radius: 0.2 },
  { path: 'web/icons/Icon-512.png', size: 512, style: 'rounded', glyph: 0.62, radius: 0.2 },
  { path: 'web/icons/Icon-maskable-192.png', size: 192, style: 'legacy', glyph: 0.44 },
  { path: 'web/icons/Icon-maskable-512.png', size: 512, style: 'legacy', glyph: 0.44 },
  { path: 'web/favicon.png', size: 32, style: 'rounded', glyph: 0.68, radius: 0.24 },
];

// ===== PNG 编码（只用 zlib，不引依赖）=====

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

/** 把 RGBA（非预乘）字节缓冲编成 PNG。 */
function encodePng(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0; // filter: None
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ===== 光栅化 =====

/**
 * 超采样画布。
 *
 * 全程用**预乘 alpha** 的浮点缓冲：超采样降采样时把 S×S 个子像素**平均**，
 * 如果再乘空间里平均，边缘会混进「透明但带颜色」的像素（半透明黑边）。
 * 这是图标边缘发灰的常见原因，所以宁可多写两行。
 */
class Raster {
  constructor(size) {
    this.size = size;
    this.W = size * SS;
    this.H = size * SS;
    this.p = new Float32Array(this.W * this.H * 4);
  }

  blend(i, r, g, b, a) {
    if (a <= 0) return;
    const p = this.p;
    const ia = 1 - a;
    p[i] = r * a + p[i] * ia;
    p[i + 1] = g * a + p[i + 1] * ia;
    p[i + 2] = b * a + p[i + 2] * ia;
    p[i + 3] = a + p[i + 3] * ia;
  }

  /** 逐超采样像素求值：`inside(x, y)` 判内，`color(x, y)` 给 [r,g,b]（0..255）。 */
  fill(x0, y0, x1, y1, inside, color) {
    const cx0 = Math.max(0, Math.floor(x0));
    const cy0 = Math.max(0, Math.floor(y0));
    const cx1 = Math.min(this.W, Math.ceil(x1));
    const cy1 = Math.min(this.H, Math.ceil(y1));
    for (let y = cy0; y < cy1; y += 1) {
      for (let x = cx0; x < cx1; x += 1) {
        const px = x + 0.5;
        const py = y + 0.5;
        if (!inside(px, py)) continue;
        const [r, g, b] = color(px, py);
        this.blend((y * this.W + x) * 4, r / 255, g / 255, b / 255, 1);
      }
    }
  }

  /** 全部画完 → 降采样 → 非预乘 RGBA 字节。 */
  toBuffer() {
    const out = Buffer.alloc(this.size * this.size * 4);
    const n = SS * SS;
    for (let y = 0; y < this.size; y += 1) {
      for (let x = 0; x < this.size; x += 1) {
        let r = 0;
        let g = 0;
        let b = 0;
        let a = 0;
        for (let dy = 0; dy < SS; dy += 1) {
          for (let dx = 0; dx < SS; dx += 1) {
            const i = ((y * SS + dy) * this.W + (x * SS + dx)) * 4;
            r += this.p[i];
            g += this.p[i + 1];
            b += this.p[i + 2];
            a += this.p[i + 3];
          }
        }
        r /= n;
        g /= n;
        b /= n;
        a /= n;
        const o = (y * this.size + x) * 4;
        // 反预乘。a 很小时颜色无意义，直接置成全透明，免得留下杂色。
        if (a > 0.004) {
          out[o] = Math.round(Math.min(1, r / a) * 255);
          out[o + 1] = Math.round(Math.min(1, g / a) * 255);
          out[o + 2] = Math.round(Math.min(1, b / a) * 255);
          out[o + 3] = Math.round(a * 255);
        }
      }
    }
    return out;
  }
}

/** 圆角矩形（或直角矩形）的点内判定。 */
function roundedRectInside(x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2);
  return (px, py) => {
    if (px < x || py < y || px > x + w || py > y + h) return false;
    const dx = Math.min(Math.max(px, x + rr), x + w - rr);
    const dy = Math.min(Math.max(py, y + rr), y + h - rr);
    const ddx = px - dx;
    const ddy = py - dy;
    return ddx * ddx + ddy * ddy <= rr * rr;
  };
}

/** 多变形的点内判定（射线法，适用于简单多边形）。 */
function polygonInside(points) {
  return (px, py) => {
    let inside = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i, i += 1) {
      const [xi, yi] = points[i];
      const [xj, yj] = points[j];
      if (yi > py !== yj > py && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  };
}

/** 竖直线性梯度。坐标用画布归一化值（0..1），与超采样倍数无关。 */
function verticalGradient(canvasPx) {
  const top = GRADIENT_TOP;
  const bottom = GRADIENT_BOTTOM;
  return (_px, py) => {
    const t = py / canvasPx;
    return [
      top[0] + (bottom[0] - top[0]) * t,
      top[1] + (bottom[1] - top[1]) * t,
      top[2] + (bottom[2] - top[2]) * t,
    ];
  };
}

const WHITE = () => [255, 255, 255];

/**
 * 画一个图标。
 *
 * three styles：
 *   `legacy`     全出血渐变底 + 白书（Android 传统图标 / maskable）
 *   `rounded`    圆角渐变底 + 白书（Web 普通图标、favicon）
 *   `foreground` 透明底 + 白书（Android 自适应图标前景层）
 */
function render({ size, style, glyph, radius = 0 }) {
  const r = new Raster(size);
  const S = r.W; // 超采样后的边长

  if (style !== 'foreground') {
    const rad = style === 'rounded' ? radius * S : 0;
    r.fill(0, 0, S, S, roundedRectInside(0, 0, S, S, rad), verticalGradient(S));
  }

  // 字形盒：宽度 = glyph × 画布，高度按 GLYPH_ASPECT 折算，居中（略微上移 1% 做视觉居中）。
  const gw = glyph * S;
  const gh = gw * GLYPH_ASPECT;
  const ox = (S - gw) / 2;
  const oy = (S - gh) / 2 - S * 0.01;
  const toCanvas = (pts) => pts.map(([px, py]) => [ox + px * gw, oy + py * gh]);

  for (const page of [PAGE_LEFT, PAGE_RIGHT]) {
    const pts = toCanvas(page);
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    r.fill(
      Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys),
      polygonInside(pts), WHITE,
    );
  }

  return encodePng(size, size, r.toBuffer());
}

// ===== 自适应图标的 XML（背景用纯色，前景用上面那张图）=====

const ADAPTIVE_XML = `<?xml version="1.0" encoding="utf-8"?>
<!--
  Android 8.0（API 26）起的自适应图标。

  背景**刻意用纯色而不是图片**：启动器做视差/缩放时会看到背景层的边缘，
  用图（尤其是带渐变的图）在放大时容易露出接缝；纯色永远安全。
  前景图的画布是 108dp，内容只占中间 44%，剩下的留白是给启动器裁切用的 ——
  这不是浪费，裁掉就没有留白了，图标边上会被啃掉一块。
-->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
`;

const COLORS_XML = `<?xml version="1.0" encoding="utf-8"?>
<!-- 图标相关颜色。由 tools/make-app-icon.mjs 生成，改配色请改那个脚本并重跑。 -->
<resources>
    <!-- 自适应图标背景层。与 lib/constants/app_colors.dart 的 primary 一致。 -->
    <color name="ic_launcher_background">${BRAND_COLOR}</color>
</resources>
`;

// ===== 主流程 =====

const checkMode = process.argv.includes('--check');
const written = [];
const missing = [];

const targets = ANDROID_ONLY ? TARGETS.filter((t) => t.path.startsWith('android/')) : TARGETS;

for (const target of targets) {
  const abs = join(repoRoot, target.path);
  if (checkMode) {
    if (!existsSync(abs)) {
      missing.push(`${target.path}（不存在）`);
      continue;
    }
    const size = readPngSize(readFileSync(abs));
    if (size === null) missing.push(`${target.path}（不是合法 PNG）`);
    else if (size.width !== target.size || size.height !== target.size) {
      missing.push(`${target.path}（尺寸 ${size.width}×${size.height}，应为 ${target.size}×${target.size}）`);
    } else written.push(`${target.path}  ${target.size}×${target.size}`);
    continue;
  }
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, render(target));
  written.push(`${target.path}  ${target.size}×${target.size}`);
}

// 两个 XML 只在生成模式下写（--check 也要核对它们，但内容比对交给 identity 脚本）
if (!checkMode) {
  const adaptivePath = join(repoRoot, 'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
  mkdirSync(dirname(adaptivePath), { recursive: true });
  writeFileSync(adaptivePath, ADAPTIVE_XML);
  written.push('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');

  const colorsPath = join(repoRoot, 'android/app/src/main/res/values/colors.xml');
  mkdirSync(dirname(colorsPath), { recursive: true });
  writeFileSync(colorsPath, COLORS_XML);
  written.push('android/app/src/main/res/values/colors.xml');
} else {
  for (const p of ['android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    'android/app/src/main/res/values/colors.xml']) {
    if (existsSync(join(repoRoot, p))) written.push(p);
    else missing.push(`${p}（不存在）`);
  }
}

/** 读 PNG 的 IHDR 尺寸 —— 用它自己生成的产物做验收，不能只信「写成功了」。 */
function readPngSize(buf) {
  if (buf.length < 24 || buf.readUInt32BE(0) !== 0x89504e47) return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

console.log(
  (checkMode ? `图标核对（共 ${targets.length} 张 + 2 个 XML）` : '生成应用图标') +
    `  配色：${PALETTE.label}`,
);
for (const line of written) console.log(`  ✓ ${line}`);
if (missing.length > 0) {
  console.log(`\n✗ ${missing.length} 处不对：`);
  for (const line of missing) console.log(`  ${line}`);
  console.log('\n重跑 `node tools/make-app-icon.mjs` 重新生成。');
  process.exit(1);
}
console.log(checkMode ? '\n✓ 全部就位。' : `\n✓ 写了 ${written.length} 个文件。`);
