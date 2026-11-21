/// 微软朗读接口的 `Sec-MS-GEC` v2 令牌。
///
/// ## 为什么单独一个文件
///
/// 这**不是公开接口**，令牌算法最容易被微软改掉（v1 是纯 SHA256，已经被服务端
/// 作废，改成现在这套）。失效时只需要替换本文件，其余代码一行不动。
///
/// ## 它不是标准 SHA256
///
/// - 初始状态由**数据头 7 个字节**决定，不是 `0x6A09E667…`；
/// - 常量表第 15 个被换成了 `0xC9DC06A7`，填充长度基准也不同；
/// - 外面再套一层 CS64（自定义 64 位混合），输出 `CS64-SHA256` 两段。
///
/// 所以**不能**用 `package:crypto` 拼。下面是从 `REA-projects/podcast/index.html`
/// 的 `gec*` 系列逐行移植的；那里的原始实现与 `edge_tts/drm.py` 对齐过，
/// 这里的判据是 `test/edge_tts_token_test.dart` 的 8 组同源向量。
///
/// 移植时只有一处不能想当然：JS 的 `Math.imul` 是 **32 位截断乘法**，
/// Dart 的 int 是 64 位，直接相乘会溢出到高位。见 [_imul]。
library;

/// 拼在 ticks 后面的固定串（不是十六进制数字，就是一个字符串常量）。
const String _trusted = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

/// Windows FILETIME 与 Unix 秒的差值（1601-01-01 → 1970-01-01）。
const int _epoch = 11644473600;

/// 服务端要求的版本号。改它要连带换令牌算法，别单独动。
const String gecVersion = '2-143.0.3650.75';

const List<int> _round = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
  0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
  0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
  0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
  0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
  0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
  0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
  0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
  0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];

const int _adj = 0xC9DC06A7;

/// 第 15 个常量被换掉的那一版轮常量（只用于 `_shaInit` 的第一段）。
final List<int> _block = [
  ..._round.sublist(0, 14),
  _adj,
  ..._round.sublist(15),
];

const List<int> _initial = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

const List<int> _state0 = [
  0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
  0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
];

const List<int> _sched = [
  0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491,
  0xC0DD25A0, 0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
  0xD258B060, 0x72766564,
];

const int _s0Adj = 0x059C0B80;
const int _s1Adj = 0x000B92C0;
const int _factor = 0x82893933;
const int _cadj0 = 0xF2F90B1A;
const int _cadj1 = 0x0B1A0000;

const List<List<int>> _coef = [
  [0xE82E91B1, 0xB32700D0], [0x44DE24C6, 0x88DFF51D],
  [0x3BEB65BC, 0x29514038], [0xC89C5933, 0xB328CBDF],
  [0x8D1EC211, 0xD405B4D5], [0x314EF5D5, 0x26E55F3C],
  [0xE92491B1, 0x607801C6], [0xF0A5B9D5, 0x82B2C1FB],
  [0x06064CF3, 0xFA51A3DA], [0xDA79FA60, 0x207CC464],
  [0xBED20560, 0x3C3C74F3], [0x89F9C9F8, 0xD2D14B61],
  [0x35FA38C6, 0xBB04A2C1], [0xCB49E3C6, 0xC5626167],
];

/// 算一个当前时刻的令牌。`unixTs` 只给测试用。
String secMsGec({int? unixTs}) {
  final seconds = unixTs?.toDouble() ??
      DateTime.now().millisecondsSinceEpoch / 1000.0;

  var ticks = seconds + _epoch;
  ticks -= ticks % 300; // 5 分钟一个窗口，服务端按同一个窗口校验
  ticks *= 1e9 / 100; // 秒 → 100 纳秒

  // ⚠️ 必须用 double 走一遍：JS 那边也是浮点，整数化会算出不同的 ticks。
  final text = '${ticks.toStringAsFixed(0)}$_trusted';
  final data = [for (var i = 0; i < text.length; i++) text.codeUnitAt(i) & 0xFF];

  final digest = _shaDigest(data);
  final cs = _cs64(data, digest);

  final csHex = _hex8(_bswap(cs[0])) + _hex8(_bswap(cs[1]));
  final shaHex = digest
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join();
  return '$csHex-$shaHex';
}

// ---------------------------------------------------------------- 32 位辅助

/// JS `Math.imul` 的等价实现：**只保留低 32 位**。
///
/// 直接 `a * b` 在 Dart 里是 64 位，两个 uint32 相乘最大约 1.8e19，
/// 已经越过 int64 上限；拆成高低 16 位乘才安全。
int _imul(int a, int b) {
  final al = a & 0xFFFF;
  final ah = (a >>> 16) & 0xFFFF;
  final bl = b & 0xFFFF;
  final bh = (b >>> 16) & 0xFFFF;
  return ((al * bl) + (((ah * bl + al * bh) & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

int _ror(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

int _rotl16(int x) => (((x & 0xFFFF) << 16) | (x >>> 16)) & 0xFFFFFFFF;

int _sigma0(int x) =>
    ((x >>> 7) ^ (x << 25) ^ (x >>> 18) ^ (x << 14) ^ (x >>> 3)) & 0xFFFFFFFF;

int _sigma1(int x) =>
    ((x >>> 17) ^ (x << 15) ^ (x >>> 19) ^ (x << 13) ^ (x >>> 10)) &
    0xFFFFFFFF;

int _bswap(int v) =>
    (((v & 0xFF) << 24) |
        (((v >>> 8) & 0xFF) << 16) |
        (((v >>> 16) & 0xFF) << 8) |
        ((v >>> 24) & 0xFF)) &
    0xFFFFFFFF;

String _hex8(int v) =>
    (v & 0xFFFFFFFF).toRadixString(16).toUpperCase().padLeft(8, '0');

// ---------------------------------------------------------------- 内部算法

void _expand(List<int> words, int first) {
  for (var i = first; i < 64; i++) {
    final x = words[i - 2];
    final y = words[i - 15];
    final s1 = _sigma1(x);
    final s0 = _sigma0(y);
    words.add((s1 + words[i - 7] + s0 + words[i - 16]) & 0xFFFFFFFF);
  }
}

List<int> _rounds(List<int> state, List<int> words, int firstRound) {
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  final k = firstRound == 14 ? _block : _round;

  for (var i = firstRound; i < 64; i++) {
    final s1 = (_ror(e, 6) ^ _ror(e, 11) ^ _ror(e, 25)) & 0xFFFFFFFF;
    final ch = (g ^ (e & (f ^ g))) & 0xFFFFFFFF;
    final t1 = (h + s1 + ch + k[i] + words[i]) & 0xFFFFFFFF;
    final s0 = (_ror(a, 2) ^ _ror(a, 13) ^ _ror(a, 22)) & 0xFFFFFFFF;
    final maj = ((a & b) | (c & (a | b))) & 0xFFFFFFFF;
    final t2 = (s0 + maj) & 0xFFFFFFFF;

    h = g;
    g = f;
    f = e;
    e = (d + t1) & 0xFFFFFFFF;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xFFFFFFFF;
  }
  return [a, b, c, d, e, f, g, h];
}

List<int> _shaInit(List<int> first7) {
  final words = List<int>.filled(14, 0, growable: true);
  words.add(((first7[0] << 16) | (first7[1] << 8) | first7[2]) & 0xFFFFFFFF);
  words.add(
    ((first7[3] << 24) |
            (first7[4] << 16) |
            (first7[5] << 8) |
            first7[6]) &
        0xFFFFFFFF,
  );

  for (var i = 16; i < 30; i++) {
    var v = _sched[i - 16];
    if (i - 2 >= 14) {
      v += (i == 16) ? (_sigma1(words[i - 2]) ^ _s1Adj) : _sigma1(words[i - 2]);
    }
    if (i - 7 >= 14) v += words[i - 7];
    if (i - 15 >= 14) {
      v += (i == 29)
          ? (_sigma0(words[i - 15]) ^ _s0Adj)
          : _sigma0(words[i - 15]);
    }
    words.add(v & 0xFFFFFFFF);
  }

  words.add(
    (_sigma1(words[28]) +
            words[23] +
            _sigma0(words[15]) +
            words[14] +
            _adj -
            _round[14]) &
        0xFFFFFFFF,
  );

  _expand(words, 31);
  final w = _rounds(_state0, words, 14);
  return [for (var i = 0; i < 8; i++) (_initial[i] + w[i]) & 0xFFFFFFFF];
}

List<int> _shaDigest(List<int> data) {
  if (data.length < 7) throw ArgumentError('令牌数据太短');

  final length = 57 + data.length;
  final zeros = (((55 - length) % 64) + 64) % 64;

  final body = data.sublist(7);
  body.add(0x80);
  for (var i = 0; i < zeros; i++) {
    body.add(0);
  }
  final bits = length * 8;
  body.addAll([
    0, 0, 0, 0,
    (bits >>> 24) & 0xFF,
    (bits >>> 16) & 0xFF,
    (bits >>> 8) & 0xFF,
    bits & 0xFF,
  ]);

  var state = _shaInit(data.sublist(0, 7));
  for (var off = 0; off < body.length; off += 64) {
    final words = <int>[];
    for (var i = 0; i < 16; i++) {
      final p = off + i * 4;
      words.add(
        ((body[p] << 24) |
                (body[p + 1] << 16) |
                (body[p + 2] << 8) |
                body[p + 3]) &
            0xFFFFFFFF,
      );
    }
    _expand(words, 16);
    final w = _rounds(state, words, 0);
    state = [for (var i = 0; i < 8; i++) (state[i] + w[i]) & 0xFFFFFFFF];
  }

  final out = <int>[];
  for (final v in state) {
    out.addAll([
      (v >>> 24) & 0xFF,
      (v >>> 16) & 0xFF,
      (v >>> 8) & 0xFF,
      v & 0xFF,
    ]);
  }
  return out;
}

List<int> _cs64(List<int> data, List<int> digest) {
  var keyA =
      (digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24)) &
      0xFFFFFFFF;
  var keyB =
      (digest[4] | (digest[5] << 8) | (digest[6] << 16) | (digest[7] << 24)) &
      0xFFFFFFFF;
  keyA |= 1;
  keyB |= 1;

  final factors = [_imul(keyA, _factor), _imul(keyB, _factor)];
  final terms = <int>[];
  final offsets = <int>[];
  for (var i = 0; i < _coef.length; i++) {
    terms.add(_imul(_coef[i][0], factors[i % 2]));
    offsets.add(_coef[i][1] & 0xFFFFFFFF);
  }

  final buf = <int>[0, ...data];
  while (buf.length % 4 != 0) {
    buf.add(0);
  }
  final words = <int>[];
  for (var i = 0; i < buf.length; i += 4) {
    words.add(
      (buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16) | (buf[i + 3] << 24)) &
          0xFFFFFFFF,
    );
  }
  if (words.length.isOdd) words.add(0);

  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    var term = _imul(word, i.isEven ? keyA : keyB);
    var offset = _imul(_rotl16(word), i.isEven ? 0xEF0569FB : 0xC31713DB);
    if (i == 0) {
      term = (term + _imul(_cadj0, factors[0])) & 0xFFFFFFFF;
      offset = (offset + _cadj1) & 0xFFFFFFFF;
    }
    terms.add(term);
    offsets.add(offset);
  }

  var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
  for (var i = 0; i < terms.length; i += 2) {
    final x = terms[i];
    final y = terms[i + 1];

    var t = _rotl16((offsets[i] + x) & 0xFFFFFFFF);
    var q = _imul(t, 0x76F50F34);
    swapAcc =
        (swapAcc + ((_imul(_rotl16(q), 0xC3EFEA97) + q) & 0xFFFFFFFF)) &
        0xFFFFFFFF;

    t = _rotl16((offsets[i + 1] + y) & 0xFFFFFFFF);
    q = _imul(t, 0x1881CE3C);
    swapLast = (_imul(_rotl16(q), 0x35BD1EC9) + q) & 0xFFFFFFFF;
    swapAcc = (swapAcc + swapLast) & 0xFFFFFFFF;

    state = (_imul(state, keyA) + x) & 0xFFFFFFFF;
    state = _imul(_rotl16(state), 0xCF98B111);
    state = _imul(_rotl16(state), 0x87085B9F);
    state = _imul(_rotl16(state), 0x12CEB96D);
    state = _imul(_rotl16(state), 0x257E1D83);
    acc = (acc + state) & 0xFFFFFFFF;

    t = (_imul(state, keyB) + y) & 0xFFFFFFFF;
    t = _imul(_rotl16(t), 0xA27416F5);
    t = _imul(_rotl16(t), 0xD38396FF);
    state = _imul(_rotl16(_imul(_rotl16(t), 0x7C932B89)), 0xBFA49F69);
    acc = (acc + state) & 0xFFFFFFFF;
  }

  return [(swapLast ^ state) & 0xFFFFFFFF, (swapAcc ^ acc) & 0xFFFFFFFF];
}
