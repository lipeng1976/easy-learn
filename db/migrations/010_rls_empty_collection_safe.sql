-- 把「解析 csv 形式的会话变量」收进一个函数，并顺手去掉空元素。
--
-- 本文件是 002_rls.sql 的**修正**，不是对它的改写 —— 002 已经应用过，改它不会重新执行。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 一、为什么要修（2026-09-24 在真 RDS 上实测出来的）
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 各 policy 里原本写着：
--
--     student_id = ANY(string_to_array(current_setting('app.visible_students', true), ','))
--
-- 实测 PG 18 的行为（下面三条是**跑出来的**，其中第二条我原先推错了）：
--
--     string_to_array('',   ',')  =  {}          ← 空数组，匹配 0 行 ✓ 安全
--     string_to_array(NULL, ',')  =  NULL        ← ANY(NULL) 为 NULL ✓ 安全
--     string_to_array(',,', ',')  =  {'','',''}  ← **含空串元素** ✗
--
-- 也就是说「整体为空串」是安全的，但「逗号分隔里出现空元素」不安全 ——
-- 它会让 `student_id = ''` 的行变得可见。而 `student_id` 恰好在 15 张业务表上是
-- `TEXT NOT NULL DEFAULT ''`。于是这条链真实存在（两个条件都罕见，且**都不报错**）：
--
--     ① 某处 insert 漏传 student_id → DEFAULT '' 静默写入一行「无主」数据；
--     ② 某次下发的集合里出现空元素 → 这行对所有用户可见。
--
-- ⚠️ `src/db.js` 第一步设的就是空串（`set_config(..., '')`），实测安全（空数组）。
--    真正危险的是**含空元素的列表**，所以修的是「解析」这一步，不是调用方。
--    这也是把它放在 policy 侧的理由：**安全边界不该依赖调用方每次都设对**。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 二、为什么用「从库里读表达式再替换」而不是手抄表名清单
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 第一版是手抄 002 的循环表名 + 几张单独写的表，结果**漏掉了 005 的
-- `notification_insert`**（它读的是另一个变量 `app.notify_targets`）——
-- 而漏掉不会报错，只会留下一条比别处宽的 policy。
--
-- 根因：policy 的**最终形状分散在 002 / 003 / 004 / 005 / 008 五个文件里**
-- （004 把 app_user 的 `own_rows` DROP 后拆成读写两条；008 又给 `user_read`
-- 加了一段 EXISTS 子查询）。照抄任何一个文件都必然与实际不符。
--
-- 所以这里改成：**从 `pg_policies` 读当前表达式，只替换那一个子表达式，其余原样保留**。
-- 好处是它不会漏（数据源就是事实），也不会把别处的改动覆盖掉。
-- 替换串用的是 `pg_get_expr` 的规范化输出（`'app.visible_students'::text`），
-- 这种文本是**可逆**的 —— 重新 parse 一定等价。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 三、函数本身
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 语义与原来完全一致，只多一步 `array_remove(..., '')`：
--
--     · 不设 / 空串  → 空数组 → 匹配 0 行（fail-closed）
--     · ',,'        → 去掉空元素后为空 → 匹配 0 行（**本文件修的就是这条**）
--     · 'a,b'       → {'a','b'}（不变）
--
-- STABLE 而不是 IMMUTABLE：它读会话变量，同一个查询里值不变、跨语句会变。
-- 标成 IMMUTABLE 会让 PG 在错误的粒度上缓存它 —— 那正是「A 看到 B 的数据」的经典成因。
-- 这一点与 `current_setting` 自身的 volatility（也是 STABLE）一致，
-- 所以 policy 里调用它的代价与原来直接写表达式**相同**。
CREATE OR REPLACE FUNCTION app_csv_setting(setting_name text) RETURNS text[]
  LANGUAGE sql
  STABLE
  AS $$
    select array_remove(
      string_to_array(current_setting(setting_name, true), ','),
      ''
    )
  $$;

-- 显式授一次执行权。PG 默认给 PUBLIC，写出来是为了让「这个函数是策略的一部分」
-- 这件事在权限清单里也看得见。
GRANT EXECUTE ON FUNCTION app_csv_setting(text) TO app_rls;

-- ═══════════════════════════════════════════════════════════════════════════
-- 四、就地替换
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  p         record;
  q         text;
  w         text;
  stmt      text;
  processed integer := 0;
  before    integer;
  after     integer;
BEGIN
  SELECT count(*) INTO before
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (qual LIKE '%string_to_array%' OR with_check LIKE '%string_to_array%');

  IF before = 0 THEN
    RAISE EXCEPTION
      '一个含 string_to_array 的 policy 都没找到 —— 本迁移的前提不成立，先查 002/005 是否真的应用过';
  END IF;

  FOR p IN
    SELECT tablename, policyname, cmd, roles::text AS roles,
           qual AS q, with_check AS w
      FROM pg_policies
     WHERE schemaname = 'public'
       AND (qual LIKE '%string_to_array%' OR with_check LIKE '%string_to_array%')
     ORDER BY tablename, policyname
  LOOP
    -- 只处理授予 PUBLIC 的 policy。若将来有 policy 只给某个角色，
    -- 静默丢掉 TO 子句会**放宽**它 —— 所以这里宁可把迁移打回去。
    IF p.roles <> '{public}' THEN
      RAISE EXCEPTION 'policy %.% 的角色是 %，本迁移不会处理非 public 的 policy',
        p.tablename, p.policyname, p.roles;
    END IF;

    q := p.q;
    w := p.w;

    IF q IS NOT NULL THEN
      q := replace(q,
        'string_to_array(current_setting(''app.visible_students''::text, true), '',''::text)',
        'app_csv_setting(''app.visible_students'')');
      q := replace(q,
        'string_to_array(COALESCE(current_setting(''app.notify_targets''::text, true), ''''::text), '',''::text)',
        'app_csv_setting(''app.notify_targets'')');
      IF q LIKE '%string_to_array%' THEN
        RAISE EXCEPTION 'policy %.% 的 USING 里还有没被替换的 string_to_array，表达式是：%',
          p.tablename, p.policyname, q;
      END IF;
    END IF;

    IF w IS NOT NULL THEN
      w := replace(w,
        'string_to_array(current_setting(''app.visible_students''::text, true), '',''::text)',
        'app_csv_setting(''app.visible_students'')');
      w := replace(w,
        'string_to_array(COALESCE(current_setting(''app.notify_targets''::text, true), ''''::text), '',''::text)',
        'app_csv_setting(''app.notify_targets'')');
      IF w LIKE '%string_to_array%' THEN
        RAISE EXCEPTION 'policy %.% 的 WITH CHECK 里还有没被替换的 string_to_array，表达式是：%',
          p.tablename, p.policyname, w;
      END IF;
    END IF;

    -- 重建。USING / WITH CHECK 按原样带过去：
    --   · INSERT policy 没有 USING（PG 不允许），这里 q 为 NULL → 不写这句；
    --   · SELECT policy 没有 WITH CHECK，同理。
    -- 「按 null 判断」而不是「按 cmd 判断」，是为了不让本文件多一份
    -- 「哪种命令允许哪种子句」的知识 —— 那份知识属于 PG，不属于这里。
    EXECUTE format('DROP POLICY %I ON %I', p.policyname, p.tablename);

    stmt := format('CREATE POLICY %I ON %I FOR %s', p.policyname, p.tablename, p.cmd);
    IF q IS NOT NULL THEN
      stmt := stmt || format(' USING (%s)', q);
    END IF;
    IF w IS NOT NULL THEN
      stmt := stmt || format(' WITH CHECK (%s)', w);
    END IF;

    EXECUTE stmt;
    processed := processed + 1;
  END LOOP;

  SELECT count(*) INTO after
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (qual LIKE '%string_to_array%' OR with_check LIKE '%string_to_array%');

  IF after <> 0 THEN
    RAISE EXCEPTION '替换后仍有 % 个 policy 含 string_to_array', after;
  END IF;

  RAISE NOTICE '已重建 % 个 policy（原先含 string_to_array 的）', processed;
END
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 五、断言：把「只有一个解析入口」写成判据，而不是写成注释
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠️ 上面那句「将来只改一处」只有当这条断言为真时才成立。哪天有人手写一个新 policy
--    直接拼 string_to_array(...)，这里会当场把迁移打回去 —— 而不是等到某次越权。
--
-- 反面：确认**确实有** policy 用上了它（否则「谁都没用」也会让上面那条通过）。
DO $$
DECLARE
  bad   integer;
  good  integer;
BEGIN
  SELECT count(*) INTO bad
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (qual LIKE '%string_to_array%' OR with_check LIKE '%string_to_array%');

  IF bad > 0 THEN
    RAISE EXCEPTION '有 % 个 policy 直接拼了 string_to_array(...)：应当改用 app_csv_setting()', bad;
  END IF;

  SELECT count(*) INTO good
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (qual LIKE '%app_csv_setting%' OR with_check LIKE '%app_csv_setting%');

  IF good < 20 THEN
    RAISE EXCEPTION '只有 % 个 policy 用上了 app_csv_setting()，预期 ≥20 —— 有 policy 被漏掉了', good;
  END IF;
END
$$;
