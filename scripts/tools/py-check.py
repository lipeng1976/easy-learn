#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
231 绕过：用 Python 调 dart 的**进程内**命令，做一个**语法**闸门。

## 为什么需要它（2026-10-03 实测）

这台机器上 **dart 运行时自己 spawn 子进程**确定性失败
`CreateFile failed 231 (ERROR_PIPE_BUSY)`，抛出点 `runtime/bin/process_win.cc:744`。
凡是要起子进程的都不行：

  - `dart analyze`   → `AnalysisServer._startProcess` 挂在 spawn analysis server 上
  - `flutter analyze` → 同一条路（flutter_tools 的 `AnalysisServer` 走 LSP）
  - `flutter test/build/pub get` → 内部要 spawn git / cmd / dartaotruntime，全挂

对照组（都是实测，不是推断）：
  - **Python 的 subprocess 完全正常**：cmd / git / dartaotruntime / dart 都能起。
  - **dart 自己进程内的命令正常**：`dart --version`、`dart format`、`dart pub get`、
    `dart language-server`（LSP 握手成功）。
  - 一个直接探针（dart 里 `Process.runSync('cmd.exe', ...)`）5 种目标 **5/5 失败**；
    换成 `ProcessStartMode.inheritStdio` **成功** —— 所以坏的**只**是 dart 建管道
    这条路，不是权限、不是环境变量、不是父进程的 stdio（三者都试过）。
  - 命名管道空间是干净的（`\\.\pipe\` 共 225 项，**没有任何 dart 管道**），
    所以不是「管子用光了」。

## 它给什么、不给什么（重要）

给：**语法**闸门。`dart format` 会真的解析每一个文件，解析不过就报
     `Could not format because the source could not be parsed` 并返回 65。
不给：**类型**闸门。它证明不了「没有类型错误、没有未定义符号、没有用错的参数名」。

⚠️ **别把这条绿灯当成 `flutter analyze` 通过。** 在 231 恢复之前，客户端
   类型检查就是一个**明摆着的缺口**，要如实说出来。
   本文件刻意不叫 py-analyze：名字不能比证据大。

## 用法

  python tools/py-check.py                     # 检查 lib/ 与 test/
  python tools/py-check.py lib test            # 指定目录
  python tools/py-check.py lib/foo.dart        # 指定文件
"""
import os
import subprocess
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLUTTER_ROOT = os.environ.get("FLUTTER_ROOT", r"C:\dev\flutter\flutter")
DART = os.path.join(FLUTTER_ROOT, "bin", "cache", "dart-sdk", "bin", "dart.exe")

# dart format 的退出码：0 = 全部解析通过；65 = 有文件解析不了。
PARSE_ERROR_EXIT = 65


def main():
    targets = sys.argv[1:] or ["lib", "test"]
    if not os.path.exists(DART):
        sys.exit(f"[fatal] 找不到 dart: {DART}（可用 FLUTTER_ROOT 覆盖）")

    print(f"[py-check] 语法闸门（dart format 解析）：{', '.join(targets)}")
    print("[py-check] ⚠️ 这只证明**语法**，不证明类型 —— 它不是 analyze。")

    r = subprocess.run(
        [DART, "format", "--output=none"] + targets,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=PROJ,
    )
    out = r.stdout.decode("utf-8", "replace").strip()
    err = r.stderr.decode("utf-8", "replace").strip()
    if out:
        print(out)
    if err:
        print(err)

    if r.returncode == PARSE_ERROR_EXIT:
        print("\n[py-check] 解析失败：上面列出的文件有**语法错误**，先修语法。")
        sys.exit(1)
    if r.returncode != 0:
        print(f"\n[py-check] dart format 退出码 {r.returncode}，不是预期的 0/65，"
              "先看上面的输出。")
        sys.exit(2)
    print("\n[py-check] ✅ 全部文件解析通过（语法层）。类型层仍然没有判据。")


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    main()
