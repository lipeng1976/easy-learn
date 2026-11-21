import 'package:flutter/widgets.dart';

/// 关掉当前最上层的东西 —— 弹窗、底部弹层、或者上一页 —— 并把结果带回去。
///
/// ## 为什么不用 `Get.back()`
///
/// 看着等价，其实差一件事。`GetNavigation.back` 里有一段 GetX 4 → 5 的
/// 兼容代码：
///
/// ```dart
/// void back<T>({T? result, bool closeOverlays = false, bool canPop = true}) {
///   if (isSnackbarOpen && !closeOverlays) {
///     closeCurrentSnackbar();
///     return;              // ← 关掉提示条就直接 return，压根不 pop
///   }
///   ...
/// }
/// ```
///
/// 于是**只要屏幕上还有一条 snackbar**（它默认要挂 3 秒），`Get.back()` 就变成
/// 「关掉那条提示条」然后什么都不做。用户看到的形态是**按钮偶尔没反应**：
///
/// - 弹窗里点「取消」或「保存」→ 弹窗不动，得再点一次（而且第二次往往就正常了，
///   因为提示条已经没了 —— 所以它极易被当成「偶发卡顿」而不是 bug）；
/// - 「返回上一页」这类按钮同理，变成点不动。
///
/// 更坏的一种：提示条刚好在自己消失的瞬间被 `close()` 第二次，
/// GetX 里那条 `assert(!_transitionCompleter.isCompleted, 'Cannot remove entry
/// from a disposed snackbar')` 会炸 —— debug 下用户看到的是红屏报错。
///
/// 这些都在 debug 下才炸/才明显，release 里表现为「有时没反应」，最难查。
///
/// ## 这里怎么绕开的
///
/// 直接用 Flutter 自己的 `Navigator.pop`：它 pop 的就是这条路由所在的
/// Navigator —— 与 `Get.back()` 在「关掉最上层」这件事上**是同一个 Navigator**，
/// 只是不去管 snackbar。语义更窄、更确定。
///
/// ## 什么时候可以仍然用 `Get.back()`
///
/// 基本没有。全仓 16 处都已经换成这个函数；新增代码也请用它。
/// 唯一的例外是那些**明确就想「先关提示条」**的地方 —— 目前一处都没有。
void popRoute<T>(BuildContext context, [T? result]) {
  Navigator.of(context).pop(result);
}
