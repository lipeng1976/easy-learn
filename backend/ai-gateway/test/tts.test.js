import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from '../src/config.js';
import {
  TTS_MAX_INPUT_CHARS,
  splitForTts,
  synthesizeTts,
} from '../src/tts.js';

// ===== 切段 =====
//
// 这一段是整条链路里唯一「错了也不会报错」的地方：切在词中间，
// 音频照样合成、照样有声音，只是那一句谁也听不懂。所以只断结果不够，
// 要断「切出来的每一段都以标点结尾」。

test('短文本不切：一段就是原文', () => {
  const segments = splitForTts('Hello. This is a lesson.');
  assert.equal(segments.length, 1);
  assert.equal(segments[0], 'Hello. This is a lesson.');
});

test('超长英文按句子切开，且每段不超上限', () => {
  const sentence = 'This is a fairly long English sentence for the reading test. ';
  const text = sentence.repeat(20); // ~1300 字符
  const segments = splitForTts(text, 480);
  assert.ok(segments.length > 1, '必须切开，否则会超厂商 600 字符上限');
  for (const segment of segments) {
    assert.ok(segment.length <= 480, `这一段 ${segment.length} 字符，超过上限`);
  }
  // 顺序不能乱，也不能丢字。段与段之间允许少一个空格（每段独立合成，
  // 段首空格没有任何意义），所以按「去掉所有空白」比对。
  assert.equal(segments.join('').replace(/\s+/g, ''), text.replace(/\s+/g, ''));
});

test('中文按句号切，不会把一句话劈成两半', () => {
  const text = '第一句话在这里。第二句话在这里！第三句话在这里？';
  const segments = splitForTts(text, 12);
  assert.deepEqual(segments, ['第一句话在这里。', '第二句话在这里！', '第三句话在这里？']);
});

test('没有标点的超长句只能硬切，但不能丢字', () => {
  const text = 'a'.repeat(1000);
  const segments = splitForTts(text, 300);
  assert.equal(segments.length, 4);
  assert.equal(segments.join(''), text);
});

test('连续标点跟着同一句走，不析出孤立的「？」', () => {
  const segments = splitForTts('真的吗？！我不信……好的。', 8);
  assert.deepEqual(segments, ['真的吗？！', '我不信……好的。']);
});

test('空白文本切出空数组，不是 [""]', () => {
  assert.deepEqual(splitForTts('   \n  '), []);
});

// ===== 合成 =====

/** 造一个假 fetch，记录请求体，返回指定的音频地址。 */
function fakeFetch({ status = 200, body, throws } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    if (throws) throw throws;
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => body ?? {
        output: { audio: { url: `https://oss.example/${calls.length}.mp3` } },
      },
    };
  };
  impl.calls = calls;
  return impl;
}

const baseOptions = {
  apiKey: 'sk-test',
  baseUrl: 'https://dashscope.example',
  model: 'qwen3-tts-flash',
  voice: 'Cherry',
};

test('正常合成：按顺序返回每段的音频地址', async () => {
  const fetchImpl = fakeFetch();
  const text = 'One. Two. Three. '.repeat(40); // 切段后多段
  const result = await synthesizeTts({ ...baseOptions, text, language: 'en', fetchImpl });

  assert.ok(result.segments.length > 1);
  assert.deepEqual(
    result.segments.map((item) => item.index),
    result.segments.map((_, index) => index),
  );
  assert.ok(result.segments.every((item) => item.url.startsWith('https://oss.example/')));
  assert.equal(result.characters, text.trim().length);
  assert.equal(result.language, 'en');
});

test('请求体带 language_type 与 format：厂商目前忽略 format，但仍要传', async () => {
  // 2026-11-07 实测：qwen3-tts-flash 只出 wav，format / sample_rate 都不生效。
  // 仍然传着它，是为了厂商哪天真支持了就直接生效，而不用回来改这行。
  const fetchImpl = fakeFetch();
  await synthesizeTts({ ...baseOptions, text: 'Hello.', language: 'en', fetchImpl });
  const sent = fetchImpl.calls[0].body;
  assert.equal(sent.input.format, 'mp3');
  assert.equal(sent.input.language_type, 'English');
  assert.equal(sent.model, 'qwen3-tts-flash');
  assert.equal(fetchImpl.calls[0].init.headers.Authorization, 'Bearer sk-test');
});

test('云端兜底固定走女声：voice 原样透传给厂商', async () => {
  // 11-08 起的区分约定：男声 = 本机缓存 / 直连微软，女声 = 云端 Qwen。
  // 客户端 /ai/tts 会显式带 voice:'Cherry'；网关不能把它换成男声，
  // 否则「一听就知道走了哪条路」当场失效。
  const fetchImpl = fakeFetch();
  await synthesizeTts({ ...baseOptions, text: 'Hello.', language: 'en', fetchImpl });
  assert.equal(fetchImpl.calls[0].body.input.voice, 'Cherry');
});

test('网关默认音色也是 Cherry（女声），老客户端不会突然变男声', () => {
  // 已核阿里云《Qwen-TTS音色列表》非实时部分（2026-10-11）：
  // Cherry = 芊悦，女性，支持英语。改默认值要同步改客户端约定。
  assert.equal(loadConfig({}).tts.voice, 'Cherry');
});

test('handler 保留「客户端 voice 优先」，否则显式带的 Cherry 会被丢掉', async () => {
  // 静态闸门：真跑 handler 要造身份 + 拦 global fetch，代价远大于它挡的
  // 那一种回归（有人把 optionalText 那行删了，客户端带的女声被静默忽略）。
  const { readFile } = await import('node:fs/promises');
  const src = await readFile(new URL('../src/handlers.js', import.meta.url), 'utf8');
  assert.match(
    src,
    /voice:\s*optionalText\(ctx\.body,\s*'voice'\)\s*\|\|\s*settings\.voice/,
  );
});

test('中文请求带 Chinese，不是把中文当英文念', async () => {
  const fetchImpl = fakeFetch();
  await synthesizeTts({ ...baseOptions, text: '这是一次朗读测试。', language: 'zh', fetchImpl });
  assert.equal(fetchImpl.calls[0].body.input.language_type, 'Chinese');
});

test('音频地址统一升级成 https：客户端只对回环地址放行了明文', async () => {
  // 不升级的后果很具体：安卓的 network_security_config 只允许 127.0.0.1 走
  // http，第三方 OSS 地址会被直接拒 —— 表现是「只有音频播不出来」。
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      output: { audio: { url: 'http://dashscope-result.example/a.wav?sig=1' } },
    }),
  });
  const result = await synthesizeTts({ ...baseOptions, text: 'Hello.', fetchImpl });
  assert.equal(result.segments[0].url, 'https://dashscope-result.example/a.wav?sig=1');
});

test('没有 Key：回 model_not_enabled，且不可重试', async () => {
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, apiKey: '', text: '你好', fetchImpl: fakeFetch() }),
    (error) => {
      assert.equal(error.code, 'model_not_enabled');
      assert.equal(error.retryable, false);
      return true;
    },
  );
});

test('超过字数上限：直接拒，不发给厂商', async () => {
  const fetchImpl = fakeFetch();
  const text = 'a'.repeat(TTS_MAX_INPUT_CHARS + 1);
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, text, fetchImpl }),
    (error) => {
      assert.equal(error.code, 'bad_request');
      return true;
    },
  );
  assert.equal(fetchImpl.calls.length, 0, '超限的请求一次都不该发出去');
});

test('凭证被拒（401）：model_auth_failed，且标记不可重试', async () => {
  const fetchImpl = fakeFetch({
    status: 401,
    body: { code: 'InvalidApiKey', message: 'Invalid API-key provided.' },
  });
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, text: 'Hello.', fetchImpl }),
    (error) => {
      assert.equal(error.code, 'model_auth_failed');
      assert.equal(error.retryable, false);
      return true;
    },
  );
});

test('厂商超时：model_timeout，可重试', async () => {
  const timeout = new Error('The operation was aborted due to timeout');
  timeout.name = 'TimeoutError';
  const fetchImpl = fakeFetch({ throws: timeout });
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, text: 'Hello.', fetchImpl }),
    (error) => {
      assert.equal(error.code, 'model_timeout');
      assert.equal(error.retryable, true);
      return true;
    },
  );
});

test('HTTP 200 但没有音频地址：model_output_invalid（这正是静默失败的样子）', async () => {
  const fetchImpl = fakeFetch({ status: 200, body: { output: { audio: {} } } });
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, text: 'Hello.', fetchImpl }),
    (error) => {
      assert.equal(error.code, 'model_output_invalid');
      return true;
    },
  );
});

test('模型没开通：model_not_enabled，不可重试', async () => {
  const fetchImpl = fakeFetch({
    status: 404,
    body: { code: 'InvalidParameter', message: 'Model not exist.' },
  });
  await assert.rejects(
    () => synthesizeTts({ ...baseOptions, text: 'Hello.', fetchImpl }),
    (error) => {
      assert.equal(error.code, 'model_not_enabled');
      assert.equal(error.retryable, false);
      return true;
    },
  );
});
