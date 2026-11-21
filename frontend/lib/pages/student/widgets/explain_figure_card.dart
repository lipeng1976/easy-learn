import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/mistake_figure.dart';
import 'practice_figure_view.dart';

/// 讲解页的「理解图」卡片：**纯展示**，不碰 controller。
///
/// ## 为什么从这里拆出来
///
/// 这张卡片有四种状态，而三种都属于「没有图」：
/// 还没点、正在画、这题不用画、这次没画成。它们在界面上长得很像，
/// 混错一个的后果都是**学生以为按钮点空了**，而那是这套 App 里
/// 最常见的 bug 类型（点了没反应、转圈停不下来）。
///
/// 拆成纯 widget 之后，四种状态都能在测试里单独摆出来看，
/// 不用为了测一张卡片去起整个登录 + 数据库。
///
/// ## 为什么图是本地画出来的
///
/// 服务端只给「点、线、标注」的坐标，[PracticeFigureView] 负责画。
/// 位图方案（模型直接出图）已经试过：图上标着 `a` 的边可以是任意长度，
/// 学生照着推理会得出基于错误前提的结论，而那张图看起来完全正常。
class ExplainFigureCard extends StatelessWidget {
  const ExplainFigureCard({
    super.key,
    required this.figure,
    required this.failure,
    required this.loading,
    required this.onGenerate,
  });

  /// 已经拿到的结论。null = 还没点过。
  final MistakeFigure? figure;

  /// 上次失败的原因。null = 没失败过。
  ///
  /// 与 [figure] 分开：失败**不是结论**，点一次还能再试；
  /// 而 `figure.drawable == false` 是结论，再点一百次也是同一句话。
  final String? failure;

  final bool loading;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _Shell(
        icon: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: '正在画…',
        subtitle: '先判断这道题值不值得画，再算坐标，通常十秒以内',
      );
    }

    if (failure != null) {
      return _Shell(
        icon: const Icon(Icons.cloud_off_outlined,
            size: 20, color: AppColors.textMuted),
        title: failure!,
        subtitle: '图没生成不影响看讲解',
        action: TextButton(onPressed: onGenerate, child: const Text('再试一次')),
      );
    }

    final result = figure;
    if (result == null) {
      return _Shell(
        icon: const Icon(Icons.architecture_outlined,
            size: 20, color: AppColors.primary),
        title: '画一张理解图',
        subtitle: '把这道题画出来，关系看得更清楚',
        trailing: const Icon(Icons.chevron_right,
            size: 18, color: AppColors.textMuted),
        onTap: onGenerate,
      );
    }

    if (!result.drawable) {
      return _Shell(
        icon: const Icon(Icons.text_fields_outlined,
            size: 20, color: AppColors.textMuted),
        title: '这道题不画图',
        subtitle: result.reason,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.architecture_outlined,
                  size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              const Text(
                '理解图',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (result.caption.isNotEmpty)
                Flexible(
                  child: Text(
                    result.caption,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 白底：图本身是墨色线条，画在卡片底色上会跟卡片边框糊在一起。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: PracticeFigureView(figure: result.figure!),
          ),
          const SizedBox(height: 6),
          // reason 是「为什么画这张图」，放图下面当读图提示；
          // caption 在标题行，两者不重复。
          Text(
            result.reason,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 单行外壳：图标 + 标题 + 副标题（+ 可选右侧操作）。
class _Shell extends StatelessWidget {
  const _Shell({
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.action,
    this.trailing,
    this.onTap,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final Widget? action;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?action,
          ?trailing,
        ],
      ),
    );

    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(14),
      child: onTap == null
          ? body
          : InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: body,
            ),
    );
  }
}
