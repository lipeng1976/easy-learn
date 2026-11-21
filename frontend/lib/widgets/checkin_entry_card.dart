import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../controllers/checkin_controller.dart';
import '../controllers/checkin_entry_state.dart';
import '../services/database_service.dart';

/// 每日概念打卡的入口卡片（家长端 / 学生端各一处，都在**计划标签页**）。
///
/// ## 为什么不放个人信息页
///
/// 打卡是「一天里要做的一件事」，和学习计划是同一类东西 —— 用户找它的路径是
/// 「今天要练什么 → 计划页」，不是「我的账号设置」。之前挂在个人信息页，
/// 本质是 prototype 阶段「别让没稳的功能占主流程」的权宜，现在功能跑通了，
/// 入口就该回到它属于的地方。
///
/// ## 为什么不是两个页面各写一份
///
/// 家长与学生的差别只有一句文案和一个跳转目标（其实是同一个页面 `/checkin`，
/// 页面自己按角色分支），各写一份的下场是两头文案/显隐条件慢慢漂开。
///
/// ## 两态两色：没做完用浅绿，做完了归灰
///
/// 浅绿是「今天还有一件事没做」的视觉提醒 —— 打卡这种小事最怕被淹在
/// 计划列表里。做完之后提醒就该退场：换成普通白卡，状态标改成「已完成」。
/// 状态来自 [CheckinEntryState]（跨页面，提交成功那一刻就翻）。
///
/// ## 本地模式下整张卡不渲染
///
/// 题目快照必须存在服务端（家长和孩子是两个账号，本地库各存一份永远对不上），
/// 本地模式点进去只会得到一句「需要联网」。与其放一张点了才告诉你不行的卡，
/// 不如不放 —— 这也是它当初挂在个人信息页 `isCloud` 分支里的原因，搬过来保留。
class CheckinEntryCard extends StatefulWidget {
  const CheckinEntryCard({super.key, this.isParent = false});

  /// 家长看到的是「设置今天的题」（选学科 / 知识点 / 题量 / 难度），
  /// 学生是一键出题。文案必须分开：用同一句会让学生以为自己也能选范围。
  final bool isParent;

  @override
  State<CheckinEntryCard> createState() => _CheckinEntryCardState();
}

class _CheckinEntryCardState extends State<CheckinEntryCard> {
  late final CheckinEntryState entry;

  @override
  void initState() {
    super.initState();
    entry = Get.isRegistered<CheckinEntryState>()
        ? Get.find<CheckinEntryState>()
        : Get.put(CheckinEntryState());
    // 每次进计划页拉一次初始值（切 tab 回来会重建这里）。
    // 已注册时也重拉：跨天的「已完成」要靠重查洗掉。
    entry.load();
  }

  @override
  Widget build(BuildContext context) {
    if (!DatabaseService.isCloud) return const SizedBox.shrink();

    final title = widget.isParent ? '概念打卡' : '每日概念打卡';
    final desc = widget.isParent
        ? '按学科、知识点、题量和难度出一组短题，出好之后孩子打开就能做。'
            '可以分科目出多份，做对做错都会记下来。'
        : '按错题本里的知识点出几道短题，一分钟能做完。'
            '做对做错都会记下来，家长能看到今天练了什么。';
    // 出题不再限定当天（2026-10-29）：说「今天的题」会让孩子以为漏了就没了。
    final pendingAction = widget.isParent ? '出新的打卡题' : '去做打卡';

    return Obx(() {
      // ⚠️ 必须无条件订阅 `progressByStudent`：未登录 / 没有结伴孩子时
      // `targetStudentId()` 返回 null，三元短路会导致一个 observable 都不取 ——
      // Obx 会因「没追踪到任何 observable」抛错。先整体读 .value 订阅，再按 key 取值。
      // RxMap<String,…> 的 [] 会把 key 当 String 强转，studentId 为 null 时直接炸，
      // 所以必须在 null 时跳过取值（仍保留了上面的 .value 订阅）。
      // ignore: invalid_use_of_protected_member —— RxMap.value 在 Obx 闭包里读是 GetX 标准写法。
      final progress = entry.progressByStudent.value;
      final studentId = CheckinController.targetStudentId();
      final day = studentId == null ? null : progress[studentId];
      // 口径 = 「还有几份没交」（跨天），与打卡页看到的是同一个数。
      // 之前按「今天」统计，于是昨天出的题今天一份也统计不到、卡片却亮着
      // 「待完成」—— 用户点进去发现没有题，2026-10-29 报的就是这条。
      final hasPending = day?.hasPending ?? false;
      final empty = day?.empty ?? true;
      final accent = hasPending || empty ? AppColors.success : AppColors.textMuted;
      // 一份都没有时按钮仍然是「出题/去做」：那时家长第一件要做的事就是出题，
      // 给个「看看历史记录」会让他绕一圈才发现没东西可看。
      final action = hasPending || empty
          ? pendingAction
          : (widget.isParent ? '看看历史记录' : '看看做过的');

      // 只有「还有没做的」才抢注意力：浅绿底 + 绿边。
      // 全做完 / 一份都没有都回归普通白卡 —— 后者尤其重要，绿标会让家长
      // 以为系统在催他，其实他自己还没出过题。
      final highlight = hasPending;
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: highlight
            ? Color.alphaBlend(AppColors.success.withValues(alpha: 0.14), AppColors.card)
            : AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: highlight
              ? BorderSide(color: AppColors.success.withValues(alpha: 0.45))
              : const BorderSide(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.fact_check_outlined, size: 20, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                  _StatusPill(day: day),
                ],
              ),
              const SizedBox(height: 8),
              Text(desc, style: const TextStyle(color: AppColors.textMuted, height: 1.5)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => Get.toNamed('/checkin'),
                  child: Text(action),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// 状态小标：`待完成 2 份`（绿）/ `已全部完成`（灰）/ `还没有题`（灰）。
///
/// 三态必须分开写：
///  · 「还没有题」和「待完成」都用绿标的话，家长没出过题也会被催；
///  · 「已全部完成」和「还没有题」都写「已完成」的话，一份没做过的人
///    会以为自己做完了。
/// 颜色之外再给一个文字判据 —— 单靠底色，色弱的孩子分不出三态。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.day});

  final CheckinProgress? day;

  @override
  Widget build(BuildContext context) {
    final hasPending = day?.hasPending ?? false;
    final empty = day?.empty ?? true;
    final label = empty
        ? '还没有题'
        : hasPending
            ? '待完成 ${day!.pending} 份'
            : '已全部完成';
    final color = hasPending ? AppColors.success : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
