// 反面确认：端到端脚本第 ③ 步不是「任何 id 都能读到」。
//  ① 格式合法但不存在的 id → 404
//  ② 拿**别人的**真照片 id、用自己的票 → 404（RLS 白送的）
//  ③ 不带票 → 401
// 三条都成立，第 ③ 步读到的才确实是「我自己的那一行」。
const BASE = process.env.E2E_BASE ?? 'http://127.0.0.1:8788';

const login = async (phone) => {
  const r = await fetch(`${BASE}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone, password: 'abc123' }),
  });
  const j = await r.json();
  return (j.data ?? j).token;
};

const t1 = await login('13800000001'); // 林小宇
const t3 = await login('13800000003'); // 林小桐

const list = await (
  await fetch(`${BASE}/data/homework/images`, {
    headers: { authorization: `Bearer ${t1}` },
  })
).json();
const rows = (list.data ?? list).items ?? [];
if (rows.length === 0) {
  console.log('没有照片行可测（先跑一次 _probe-photo-e2e.mjs）');
  process.exit(1);
}
const mine = rows[0].id;

const probe = async (label, id, token) => {
  const r = await fetch(
    `${BASE}/data/homework/images/file?id=${encodeURIComponent(id)}`,
    { headers: token ? { authorization: `Bearer ${token}` } : {} },
  );
  console.log(`  ${r.status === 404 || r.status === 401 ? '✓' : '✗'} ${label} → HTTP ${r.status}`);
  return r.status;
};

let bad = 0;
console.log('读图判据的反面：');
if ((await probe('格式合法但不存在的 id（本人票）', 'no-such-id-0000', t1)) !== 404) bad++;
if ((await probe('林小宇的真照片 id + 林小桐的票', mine, t3)) !== 404) bad++;
if ((await probe('不带票', mine, '')) !== 401) bad++;

console.log(
  bad === 0
    ? '\n反面全部成立 —— 第 ③ 步读到的确实是「我自己的那一行」，不是「随便谁都读得到」'
    : `\n有 ${bad} 条反面没成立`,
);
process.exit(bad === 0 ? 0 : 1);
