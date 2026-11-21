import 'package:easy_learn_app/services/edge_tts_token.dart';
import 'package:flutter_test/flutter_test.dart';

/// 令牌算法的判据。
///
/// 向量由 `REA-projects/podcast/index.html` 里那份 JS 参考实现跑出来
/// （它又与 `edge_tts/drm.py` 逐条对齐过）。算法错一位，这里就红一片 ——
/// 而线上表现是稳定的 403，从报错里完全看不出是算法的问题。
void main() {
  const vectors = <int, String>{
    1700000000:
        '2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2',
    1735689600:
        '54404AFE67C9B44A-E72E51D8B4F5F75E9A96B7E20D7877227455BC310433BD30C817CD54A1D9313E',
    1767225600:
        '723A6EBC411B23BB-214991EA6B1E401F3D777A699DDDEE75E29740EA7A5DCD1007366FA1090DD267',
    1767225900:
        '9CAC84B3EB149BCE-3B9C1E72659FFE57A42F9DC0AE026C5E0006449047F517F0E4C7254B51AF10EF',
    1786291200:
        'D222F6F1DBAF3DDD-7DD9680B0897A7CB36D206D4A894402D3EAE6077922D512F741949E9B901936D',
    1790000000:
        'D4216A7D3DE0C94F-91D741832FD084A110FDAD52BE2FFA569C6EA5F7D06A9429380A398738F4559A',
    1800000000:
        '99E54519B490BE5C-E162DB0977FBDCB9B86DD8148BF1BCDC3C0303176CE39852A42B415935C20654',
    1812345678:
        '3586D34D3DAC4675-EB199F675633E1EB95E4CECD9A80615D742EC8A02EE272EDA4034CC473F7D8BB',
  };

  test('8 组向量逐条一致', () {
    vectors.forEach((ts, expected) {
      expect(secMsGec(unixTs: ts), expected, reason: 'unixTs=$ts');
    });
  });

  test('5 分钟窗口内不变，跨窗口换新', () {
    // 1767225600 是 300 的整数倍
    final base = secMsGec(unixTs: 1767225600);
    expect(secMsGec(unixTs: 1767225600 + 299), base);
    expect(secMsGec(unixTs: 1767225600 + 300), isNot(base));
  });

  test('令牌形状固定：16 位 CS64 + 64 位 SHA256', () {
    final token = secMsGec();
    final parts = token.split('-');
    expect(parts, hasLength(2));
    expect(parts[0], matches(RegExp(r'^[0-9A-F]{16}$')));
    expect(parts[1], matches(RegExp(r'^[0-9A-F]{64}$')));
  });
}
