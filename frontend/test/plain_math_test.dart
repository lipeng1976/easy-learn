import 'package:easy_learn_app/utils/plain_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// 印在纸上的文字清洗。
///
/// 为什么要单独盯：卷子上的 `$2x$` 不是「公式没渲染」的界面问题，
/// 而是**印出来就是废纸** —— 家长看到满纸美元符号和反斜杠，
/// 只会认为程序坏了。
void main() {
  test('行内公式去掉定界符', () {
    expect(plainMathText(r'当 $x>20$ 时'), '当 x>20 时');
    expect(plainMathText(r'答案 $2x$'), '答案 2x');
  });

  test('块级公式不留下多余的美元符号', () {
    expect(plainMathText(r'$$\frac{1}{2}$$'), '1/2');
    expect(plainMathText(r'\[x+y\]'), 'x+y');
    expect(plainMathText(r'\(a+b\)'), 'a+b');
  });

  test('分式、根式转成可读写法', () {
    expect(plainMathText(r'$\frac{1}{2}+\frac{1}{3}$'), '1/2+1/3');
    expect(plainMathText(r'$\sqrt{5}$'), '√(5)');
    expect(plainMathText(r'$\text{元}$'), '元');
  });

  test('常见命令换成符号，且长命令不会被短命令截断', () {
    expect(plainMathText(r'$20 \times 2$'), '20 × 2');
    expect(plainMathText(r'$6 \div 3$'), '6 ÷ 3');
    expect(plainMathText(r'$x \leq 5$'), 'x ≤ 5');
    expect(plainMathText(r'$x \geq 5$'), 'x ≥ 5');
    // ⚠️ `\le` 是 `\leq` 的前缀：按长度倒序替换才不会切出 `≤q`。
    expect(plainMathText(r'$a \leqslant b$'), 'a ≤ b');
    expect(plainMathText(r'$a \neq b$'), 'a ≠ b');
  });

  test('没有公式的文本原样返回（只压多余空白）', () {
    expect(plainMathText('忘了进位'), '忘了进位');
    expect(plainMathText('  两处  空格  '), '两处 空格');
    expect(plainMathText(''), '');
  });

  test('不认识的命令去掉反斜杠，但不吞掉后面的字', () {
    expect(plainMathText(r'$\alpha + \beta$'), 'α + β');
    expect(plainMathText(r'$\foo 2$'), 'foo 2');
  });
}
