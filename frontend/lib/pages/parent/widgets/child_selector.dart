import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';

/// 孩子选择器（卡片样式）：用于每日点评等页面顶部
class ChildSelectorCard extends StatelessWidget {
  final List<ParentChild> students;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const ChildSelectorCard({
    super.key,
    required this.students,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选择孩子',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: students
                .map(
                  (child) => ChoiceChip(
                    label: Text(child.name),
                    selected: child.id == selectedId,
                    showCheckmark: false,
                    selectedColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: child.id == selectedId
                          ? Colors.white
                          : AppColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => onSelect(child.id),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

/// 孩子选择器（AppBar 紧凑下拉样式）：家长端全局切换查看的孩子
class ChildSelectorDropdown extends StatelessWidget {
  final List<ParentChild> students;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const ChildSelectorDropdown({
    super.key,
    required this.students,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final selected = students.firstWhere(
      (child) => child.id == selectedId,
      orElse: () => students.first,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 6, top: 4, bottom: 4),
        // 封一个上限，免得在平板/横屏上被拉成一整条。
        // 窄屏不受影响：`ConstrainedBox` 只会**收紧**，不会突破父级给的上限，
        // 所以它仍然是「最多 180，不够就跟着缩」。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected.id,
              isDense: true,
              // ⚠️ 这一行是**溢出标记的根因**，不是样式偏好，改动前先读完这段。
              //
              // AppBar 给标题区的宽度是有限的（它那边留了几个按钮见
              // `parent_app_bar.dart`，那里的数字就是按这里的需求定的）。
              // 而 `DropdownButton` 的 `isExpanded` 默认为 **false**，此时它
              // 内部那个 `Row(spaceBetween)` **不会**把内容包进 `Expanded`
              // （`dropdown.dart`：`if (widget.isExpanded) Expanded(...) else ...`），
              // 于是 `innerItemsWidget` 拿到的是**无界宽度**，我们给的
              // `Row(mainAxisSize.min)` 就按内容自然宽度撑开 —— 一旦超过
              // 可用宽度，溢出的是**它自己那个 Row**，报错指向
              // `DropdownButton`，看起来跟我们写的代码无关。
              //
              // 症状：孩子多于 1 个时，下拉控件右侧出现黄黑斜纹 +
              // 「OVERFLOWED BY n PIXELS」。实测（顶栏还留着 5 个按钮时）
              // 360dp 溢 51px、393dp 溢 18px，412dp 才刚好放得下 ——
              // 也就是**绝大多数手机都是红的**。
              //
              // 打开它之后内容才拿到有界宽度，下面那个 `Flexible` 才有意义。
              isExpanded: true,
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white,
                size: 22,
              ),
              dropdownColor: AppColors.primary,
              borderRadius: BorderRadius.circular(12),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
              selectedItemBuilder: (context) => students
                  .map(
                    (child) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.face_retouching_natural,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        // 配合上面的 `isExpanded: true`：宽度不够时**缩名字**，
                        // 而不是让整行撑破。名字被省略总比出现一个看不懂的
                        // 斜纹标记好 —— 后者会让用户以为界面坏了。
                        Flexible(
                          child: Text(
                            child.name,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.swap_horiz,
                          color: Colors.white,
                          size: 18,
                        ),
                      ],
                    ),
                  )
                  .toList(),
              items: students
                  .map(
                    (child) => DropdownMenuItem<String>(
                      value: child.id,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            child.id == selected.id
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            child.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id != null && id != selectedId) onSelect(id);
              },
            ),
          ),
        ),
      ),
    );
  }
}
