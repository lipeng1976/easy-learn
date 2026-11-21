import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';
import '../../shared/daily_comment_page.dart';
import 'child_selector.dart';

/// 家长端顶栏。
///
/// ## 为什么单独抽成一个组件
///
/// 这里原来藏着一个**只在真机上才看得见**的 bug：孩子多于 1 个时，标题换成
/// 「孩子下拉选择器」，紧挨着它就会出现一个黄黑斜纹的
/// 「OVERFLOWED BY 51 PIXELS」标记 —— 用户看到的是「一个看不懂的图标」。
///
/// 它没法在页面上顺手修好，因为原因跨了两个地方：**AppBar 的 5 个按钮**
/// 吃掉了 240dp（393dp 的机器只剩约 103dp 给标题），而**下拉控件本身**
/// 在 `isExpanded == false` 时会按内容自然宽度撑开、不接受收缩
/// （详见 `child_selector.dart` 里那段）。抽出来之后这个「宽度预算」
/// 才是一个可以被测试钉住的东西：`test/parent_app_bar_test.dart` 直接按
/// 真机宽度渲染它，断言既「不溢出」也「名字没被省略」——
/// 只有前者的话，把名字藏起来（宽度 0）也能算通过。
///
/// 参数全是**普通值**、不是控制器：这样测试里给几个字面量就能渲染，
/// 不需要连库、也不需要装一整套控制器。
class ParentAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ParentAppBar({
    super.key,
    required this.students,
    required this.selectedId,
    required this.onSelect,
    required this.unreadCount,
  });

  /// 已结伴的孩子。**多于一个**时才把标题换成下拉选择器 ——
  /// 只有一个孩子时那个下拉没有任何可切换的东西，只是白占宽度。
  final List<ParentChild> students;
  final String selectedId;
  final ValueChanged<String> onSelect;

  /// 未读消息数，用于铃铛上的红点。
  final int unreadCount;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: students.length > 1
          ? ChildSelectorDropdown(
              students: students,
              selectedId: selectedId,
              onSelect: onSelect,
            )
          : const Text('家长端'),
      actions: [
        Stack(
          alignment: Alignment.topRight,
          children: [
            IconButton(
              onPressed: () => Get.toNamed('/notifications'),
              icon: const Icon(Icons.notifications_active_outlined),
              tooltip: '消息通知',
            ),
            if (unreadCount > 0)
              const Positioned(
                right: 8,
                top: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(width: 10, height: 10),
                ),
              ),
          ],
        ),
        // 家长每天都会做的一件事：看一眼孩子的今天，写一句点评。
        // 它值得留在顶栏上。
        IconButton(
          onPressed: () => Get.to(() => const DailyCommentPage()),
          icon: const Icon(Icons.edit_note_outlined),
          tooltip: '每日点评',
        ),
        // 其余三个收进「更多」。
        //
        // 这不是审美取舍，是**宽度预算**：顶栏上每多一个按钮就少 48dp，
        // 而标题那边要放下「头像 + 孩子名字 + 切换图标 + 下拉箭头」至少
        // 需要约 121dp。5 个按钮时只剩 103dp —— 名字必然被省略，窄一点的
        // 机器（360dp）甚至会被压到 0 宽度，等于看不见。3 个按钮留出
        // 199dp，最长的名字也能完整显示。
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) {
            switch (value) {
              case 'binding':
                Get.toNamed('/binding');
              case 'chat':
                Get.toNamed('/chat');
              case 'profile':
                Get.toNamed('/profile');
              case 'help':
                Get.toNamed('/help');
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'chat',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.chat_bubble_outline),
                title: Text('伴学消息'),
              ),
            ),
            PopupMenuItem(
              value: 'binding',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.group_outlined),
                title: Text('伴学绑定'),
              ),
            ),
            PopupMenuItem(
              value: 'profile',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.person_outline),
                title: Text('个人信息'),
              ),
            ),
            PopupMenuItem(
              value: 'help',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.help_outline),
                title: Text('使用帮助'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
