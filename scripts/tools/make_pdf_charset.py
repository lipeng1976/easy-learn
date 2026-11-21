# 生成 PDF 用的中文字符集。
#
# 为什么要这么一长串：`pdf` 包不内嵌字体就只能画方块，而完整
# Noto Sans SC 有 17MB —— 直接进 APK 不值得。这里取「GB2312 全部汉字
# （6763 字）+ ASCII + 常用中日韩标点 + 数学符号」，覆盖日常题目绰绰有余。
#
# 字体本体是 Windows 自带的 Noto Sans SC（SIL OFL 1.1，允许嵌入与分发），
# **不是** 微软雅黑/黑体那类有版权的字体。
import sys

chars = set()

# ASCII 可见字符
for code in range(0x20, 0x7F):
    chars.add(chr(code))

# Latin-1 补充区：`·`（U+00B7）就在这儿，而它是标题分隔符里最高频的一个。
# ⚠️ 漏了它不会报错，只会在生成时打一行 warning，PDF 上那个位置就是空白 ——
#    2026-10-21 就是靠探针测试才发现「错题重做卷 · 一元一次方程」少了中点。
for code in range(0x00A0, 0x0100):
    chars.add(chr(code))

# Latin Extended-A：带声调的拼音（á à ǎ 等），语文卷面会用到
for code in range(0x0100, 0x0180):
    chars.add(chr(code))

# GB2312 全部汉字与符号（区位 0xB0A1–0xF7FE）
for high in range(0xB0, 0xF8):
    for low in range(0xA1, 0xFF):
        try:
            chars.add(bytes([high, low]).decode("gb2312"))
        except UnicodeDecodeError:
            pass

# 中文标点 / 全角符号 / 常用单位与数学符号
for start, end in [
    (0x3000, 0x303F),   # CJK 标点
    (0xFF00, 0xFF65),   # 全角 ASCII、半角片假名
    (0x2010, 0x2027),   # 连字符、引号、省略号
    (0x2030, 0x2044),
    (0x2116, 0x2122),
    (0x2160, 0x2179),   # 罗马数字
    (0x2190, 0x21FF),   # 箭头
    (0x2200, 0x22FF),   # 数学运算符
    (0x2460, 0x24FF),   # 带圈数字 ①②③
    (0x2500, 0x257F),   # 制表符
    (0x25A0, 0x25FF),   # 几何图形
    (0x2600, 0x26FF),
]:
    for code in range(start, end + 1):
        chars.add(chr(code))

# 题目里高频但不在上述区间的字符
chars.update("℃℉±×÷≠≈≤≥∞∠△△⊥∥∵∴π√²³½¼¾‰°′″")

sys.stdout.write("".join(sorted(chars)))
