import 'package:flutter/material.dart';

/// 学科配色：**同一门课在配置区和出题区必须是同一个颜色**。
///
/// 颜色只是第二重线索 —— 每块上都写着科目名（见 `SubjectBoard` 的注释：
/// 只靠底色区分，色弱的孩子和家长分不出来）。
///
/// 色值取自设计系统的 400 档（在白底上有足够对比度）；深浅不一的目的是
/// 「扫一眼就知道是哪科」，不是装饰。
///
/// ## 数学为什么是这种蓝（2026-11-12 虫子反馈）
///
/// 原来是 `#378ADD`（钢蓝），配 12% 的浅底之后跟页面底色 `#F5F7FF`
/// 几乎同一个色系 —— 虫子原话「数学的蓝色和界面的灰色接近了，不够醒目」。
/// 页面底色本身就是淡蓝灰，**同色系的浅底叠上去等于没有颜色**。
/// 改成饱和度更高的 `#1F6FEB`，并把浅底整体提到 0.16~0.18（见
/// `SubjectBoard` / `checkin_page`），让色块在白卡上真的能看出色相。
const Map<String, Color> kSubjectColors = <String, Color>{
  '语文': Color(0xFFD85A30),
  '数学': Color(0xFF1F6FEB),
  '英语': Color(0xFF639922),
  '物理': Color(0xFF7F77DD),
  '化学': Color(0xFF1D9E75),
  '生物': Color(0xFF97C459),
  '历史': Color(0xFFBA7517),
  '地理': Color(0xFF0F6E56),
  '政治': Color(0xFFA32D2D),
  '其他': Color(0xFF888780),
};

/// 未知科目（白名单外）给中性灰，不抛错 —— 老数据里可能有已下线的科目名。
Color subjectColor(String subject) =>
    kSubjectColors[subject] ?? kSubjectColors['其他']!;
