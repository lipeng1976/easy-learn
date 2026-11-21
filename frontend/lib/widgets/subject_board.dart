import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../constants/subject_colors.dart';
import '../controllers/parent_controller.dart';
import '../controllers/subject_board_controller.dart';
import '../models/subject_scope.dart';
import '../services/database_service.dart';

/// 家长端计划页的「今天练什么」：**上半配置、下半出题**。
///
/// ## 为什么合并成一块，而不是四张并列卡
///
/// 之前这里是三张平级卡（概念打卡 / 阅读 / 单词），家长要回答两个问题
/// 得分别进三个入口，而且「配置」和「出题」混在同一张卡里 —— 配一次的事
/// 和每天做的事长得一样。现在按**时间尺度**分两层：
///   · 上：学科范围（一年改几次）；
///   · 下：今天出什么（每天点一下）。
///
/// ## 十科都能出题（只有选择题 / 判断题）
///
/// 11-12 之前只有数学这块能真正出题，其余科目显示「出题待开放」且不可点。
/// 现在十科全开：题型统一为 choice / judge，本地能确定性判分，不需要新增
/// 判分链路。英语仍是特例 —— 它的题由学生端按词表自动出，这里点进去看记录。
///
/// ## 本地模式整块不渲染
///
/// 与 `CheckinEntryCard` 同一条理由：范围存在服务端（父子两个账号），
/// 本地模式点进去只会得到一句「需要联网」。
class SubjectBoard extends StatefulWidget {
  const SubjectBoard({super.key});

  @override
  State<SubjectBoard> createState() => _SubjectBoardState();
}

class _SubjectBoardState extends State<SubjectBoard> {
  late final SubjectBoardController controller;
  Worker? _worker;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<SubjectBoardController>()
        ? Get.find<SubjectBoardController>()
        : Get.put(SubjectBoardController());
    if (Get.isRegistered<ParentController>()) {
      // 切孩子后配置与待完成都得换人：不重建的话，家长会拿哥哥的范围
      // 给弟弟出题（同一个坑在单词卡片上踩过）。
      _worker = ever<String>(
        Get.find<ParentController>().selectedStudentId,
        (_) => controller.load(),
      );
    }
    controller.load();
  }

  @override
  void dispose() {
    _worker?.dispose();
    super.dispose();
  }

  /// [forTextbook]：英语有**两本资料**，两套范围各自有配置页 ——
  /// 词表在 `/word-scope`（`word_scope`），教材在 `/subject-scope`（`subject_scope`）。
  /// 不合成一个入口：家长改教材时不应顺手把词表也改了。
  Future<void> _openConfig(String subject, {bool forTextbook = false}) async {
    if (subject == '英语' && !forTextbook) {
      await Get.toNamed('/word-scope');
    } else {
      final saved = await Get.toNamed('/subject-scope', arguments: subject);
      if (saved == true) await controller.load();
    }
    await controller.load();
  }

  Future<void> _drill(String subject) async {
    final scope = controller.scopeOf(subject);
    // 有教材就按章节出，没教材就用手填知识点。两样都没有时**不发请求**：
    // 服务端只会回一句「还没有出题范围」，而家长点的是「出一组」，
    // 看到报错会以为自己点错了。直接进配置页，那里能选教材。
    final hasRange = (scope.bookId ?? '').isNotEmpty || scope.points.isNotEmpty;
    if (!scope.configured || !hasRange) {
      if (scope.configured) {
        controller.hint.value = '$subject还没有出题范围，先选教材或填两个知识点。';
      }
      // 英语要点的是「教材题」，没范围时得送进**教材范围**页，不是词表页。
      await _openConfig(subject, forTextbook: subject == '英语');
      return;
    }
    final ok = await controller.generate(subject);
    if (ok) {
      // 出完直接进列表：家长能看见刚出的那份，也知道孩子要做的是什么。
      await Get.toNamed('/checkin');
      await controller.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DatabaseService.isCloud) return const SizedBox.shrink();
    return Obx(() {
      final scopes = kSubjectNames
          .map((subject) => controller.scopeOf(subject))
          .toList();
      final configured = scopes.where((one) => one.configured).toList();
      final pending = controller.pendingBySubject;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('学科范围', trailing: '配一次长期有效'),
          _scopeCard(configured, scopes),
          const SizedBox(height: 16),
          _sectionLabel('今天出什么', trailing: '点色块就出 · $kCheckinQuestionTypesLabel'),
          _drillGrid(pending),
          if (controller.hint.value != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                controller.hint.value!,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          const SizedBox(height: 10),
          _moreSubjects(scopes),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Get.toNamed('/checkin'),
              child: const Text('打卡记录与历史 ›'),
            ),
          ),
        ],
      );
    });
  }

  // ===== ① 配置区 =====

  /// 已配置的科目按白名单顺序列成行；一个都没配时给一句引导。
  ///
  /// 没配的科目**不逐行列出**（十科全列会把出题区推出屏幕），
  /// 收在下面 `_moreSubjects` 的小色块里 —— 入口还在，只是不占主位。
  Widget _scopeCard(List<SubjectScope> configured, List<SubjectScope> all) {
    if (configured.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '还没有配过学科范围',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                '先配一科：选好题量、难度和范围，之后每天点色块就能出题，不用再选。',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => _openConfig('数学'),
                  child: const Text('先配数学'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < configured.length; i++)
            _ScopeRow(
              scope: configured[i],
              // 英语一行显示**两套**摘要：上册是教材范围（`subject_scope`），
              // 下册是词表（`word_scope`）。谁都不覆盖谁 —— 覆盖掉一个，
              // 家长就会以为另一本没配。
              summary: configured[i].subject == '英语'
                  ? (controller.scopes.containsKey('英语')
                      ? configured[i].summary
                      : '教材未配')
                  : configured[i].summary,
              secondarySummary: configured[i].subject == '英语'
                  ? (controller.wordSummary.value.isEmpty
                      ? '词表未配'
                      : controller.wordSummary.value)
                  : null,
              // 英语行尾两个入口：各进各的配置页。整行点击仍保持旧行为（词表页）。
              secondaryLabel: configured[i].subject == '英语' ? '教材' : null,
              onEditSecondary: configured[i].subject == '英语'
                  ? () => _openConfig('英语', forTextbook: true)
                  : null,
              showDivider: i != configured.length - 1,
              onEdit: () => _openConfig(configured[i].subject),
            ),
        ],
      ),
    );
  }

  // ===== ② 出题区 =====

  /// 四个主科色块（2×2）。顺序刻意是「数学 → 语文 → 英语 → 历史」：
  /// 数学与英语是现在真能出题的，放在左上与左下，扫视起点就能用。
  Widget _drillGrid(RxMap<String, int> pending) {
    const rows = <List<String>>[
      <String>['数学', '语文'],
      <String>['英语', '历史'],
    ];
    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          // IntrinsicHeight：让同一行的两块等高（内容长短不一），
          // 同时给出确定高度 —— 直接 stretch 在 ListView 里会拿到
          // 无限高约束，整页布局直接抛 `BoxConstraints forces an infinite height`。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < rows[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: 10),
                  Expanded(child: _tile(rows[r][c], pending[rows[r][c]] ?? 0)),
                ],
              ],
            ),
          ),
          if (r != rows.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// 色块点击的三种语义：英语看记录 / 未配置去配置 / 已配置出题。
  ///
  /// 分成一个方法而不是三元表达式：三条路径的副作用不同（导航 vs 调模型），
  /// 挤在 `onTap:` 里会让人读不出「点了到底会发生什么」。
  Future<void> _onTileTap(String subject) async {
    if (subject == '英语') {
      if (controller.wordSummary.value.isEmpty) {
        await _openConfig(subject);
        return;
      }
      await Get.toNamed('/word-daily-logs');
      return;
    }
    if (!controller.scopeOf(subject).configured) {
      await _openConfig(subject);
      return;
    }
    await _drill(subject);
  }

  Widget _tile(String subject, int pendingCount) {
    final color = subjectColor(subject);
    final scope = controller.scopeOf(subject);
    final busy = controller.isGenerating(subject);
    final isEnglish = subject == '英语';
    final wordReady = controller.wordSummary.value.isNotEmpty;

    String status;
    String body;
    String action;
    if (isEnglish) {
      // 英语有两套题：单词题由孩子端按词表本地自动出（主色块 = 看记录）；
      // 教材题（语法 / 时态 / 句型）由家长点下面第二个动作调 AI 出。
      // 两本资料各管各的，不合并成一份范围。
      status = wordReady ? '每天自动出题' : '未配词表';
      final today = controller.wordToday.value;
      body = !wordReady
          ? '先选一本教材词表'
          : (today.isEmpty ? controller.wordSummary.value : '$today\n${controller.wordSummary.value}');
      action = wordReady ? '看记录 ›' : '去配置 ›';
    } else if (!scope.configured) {
      status = '未配置';
      body = '先配范围，再出题';
      action = '去配置 ›';
    } else if (busy) {
      status = '出题中';
      body = scope.summary;
      action = '请稍候…';
    } else if (pendingCount > 0) {
      status = '待完成 $pendingCount 份';
      body = scope.summary;
      action = '再出一组 ›';
    } else {
      status = '今天还没出';
      body = scope.summary;
      action = '出一组 ›';
    }

    // 可点性：**未配置的科目必须能点**（点了进配置页），否则家长看到
    // 「去配置 ›」却没有反应 —— 这比没有入口更糟。出题中不可重复点。
    final tappable = !busy;
    final actionStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: color.withValues(alpha: tappable ? 1 : 0.55),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: !tappable ? null : () => _onTileTap(subject),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // 浅底从 0.12 提到 0.18：页面底色本身就是淡蓝灰，同色系的
          // 浅底叠上去几乎看不出颜色（数学那块尤其明显）。
          color: color.withValues(alpha: tappable ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: tappable ? 0.45 : 0.22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 6),
                // 科目名必须写着：只靠底色区分，色弱的人分不出哪块是哪科。
                // 窄屏（360dp）下「英语」+「孩子本地出题」会挤爆一行，
                // 所以两边都可缩、都可省略号 —— 宁可少几个字，不要溢出红条。
                Expanded(
                  child: Text(
                    subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.text, height: 1.45),
            ),
            const SizedBox(height: 8),
            if (isEnglish)
              // 英语两本资料 = 两个动作。Wrap 而非 Row：360dp 窄屏下
              // 「看记录 ›」+「出一组教材题 ›」并排会溢出成红条。
              Wrap(
                spacing: 10,
                runSpacing: 2,
                children: <Widget>[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: tappable ? () => _onTileTap(subject) : null,
                    child: Text(action, style: actionStyle),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: tappable ? () => _drill(subject) : null,
                    child: Text('出一组教材题 ›', style: actionStyle),
                  ),
                ],
              )
            else
              Text(action, style: actionStyle),
          ],
        ),
      ),
    );
  }

  /// 其余科目（十科里没进主位的）用小色块列出来：**入口都在，不占主屏**。
  Widget _moreSubjects(List<SubjectScope> all) {
    final rest = all.where((one) => !const <String>['数学', '语文', '英语', '历史']
        .contains(one.subject)).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: rest.map((scope) {
        final color = subjectColor(scope.subject);
        return ActionChip(
          avatar: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          label: Text(
            scope.configured ? '${scope.subject} · 已配' : scope.subject,
            style: TextStyle(fontSize: 12, color: color),
          ),
          onPressed: () => _openConfig(scope.subject),
        );
      }).toList(),
    );
  }

  Widget _sectionLabel(String text, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(
              text,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              // 右侧说明变长（「点色块就出 · 只出选择题 · 判断题」）后，
              // 360dp 屏上写死宽度会直接把这一行撑出红条。给剩余空间 + 省略号。
              Expanded(
                child: Text(
                  trailing,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ),
            ],
          ],
        ),
      );
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.scope,
    required this.summary,
    required this.onEdit,
    this.showDivider = true,
    this.secondarySummary,
    this.secondaryLabel,
    this.onEditSecondary,
  });

  final SubjectScope scope;
  final String summary;
  final VoidCallback onEdit;
  final bool showDivider;

  /// 英语专用：第二套摘要（词表）与第二配置入口（教材范围页）。
  /// 其余科目为 null，版面与原来完全一致。
  final String? secondarySummary;
  final String? secondaryLabel;
  final VoidCallback? onEditSecondary;

  Widget _actionLabel(String text, VoidCallback onTap, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final color = subjectColor(scope.subject);
    return InkWell(
      onTap: onEdit,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Text(
                    scope.subject,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: secondarySummary == null
                      ? Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                            Text(
                              secondarySummary!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                          ],
                        ),
                ),
                if (onEditSecondary != null) ...<Widget>[
                  _actionLabel('词表', onEdit, color),
                  _actionLabel(secondaryLabel ?? '配置', onEditSecondary!, color),
                ] else
                  Text('配置', style: TextStyle(fontSize: 12, color: color)),
              ],
            ),
          ),
          if (showDivider) const Divider(height: 1, indent: 12, endIndent: 12),
        ],
      ),
    );
  }
}
