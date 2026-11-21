#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
绕过 Windows「CreateFile failed 231 (ERROR_PIPE_BUSY)」构建 Flutter APK/Web。

背景（2026-10-01 实测定位）：
  - 这台机器上，node 和 dart 两个运行时「spawn 子进程（stdin 方向管道）」确定性失败 231。
  - 而 Python 的 subprocess 完全正常（CPython 的 spawn 实现不触发该 bug）。
  - flutter 工具是 dart 写的，它内部调 frontend_server / gen_snapshot / dart2js /
    gradle 时都用 dart 的 Process.start（stdin=pipe），所以 flutter build 必崩。
  - 但 frontend_server / gen_snapshot / dart2js 这些编译器本身是【单进程】，
    只要被 Python 直接调（而不是被 dart VM spawn），就能正常跑通。

绕法（本脚本做的事）：
  APK:
    1. Python 直调 dartaotruntime + frontend_server_aot.dart.snapshot -> app.dill
    2. Python 直调 gen_snapshot（三架构）-> app.so
    3. 把 app.so 放到 gradle 期望的 intermediates 目录 + touch 输出文件
    4. 拦截 flutter.bat 的 assemble 子命令（返回成功），Python 直调 gradlew 打包
  Web:
    1. Python 直调 dartaotruntime + dart2js_aot.dart.snapshot（两阶段）-> main.dart.js
    2. 覆盖 build/web/main.dart.js（其余资源复用旧产物）

用法：
  python tools/build-bypass-231.py apk
  python tools/build-bypass-231.py web
  python tools/build-bypass-231.py all
"""
import subprocess, os, shutil, time, sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FLUTTER_ROOT = r"C:\dev\flutter\flutter"
DART_SDK = os.path.join(FLUTTER_ROOT, "bin", "cache", "dart-sdk", "bin")
DARTAOTRUNTIME = os.path.join(DART_SDK, "dartaotruntime.exe")
FRONTEND_SERVER = os.path.join(DART_SDK, "snapshots", "frontend_server_aot.dart.snapshot")
DART2JS = os.path.join(DART_SDK, "snapshots", "dart2js_aot.dart.snapshot")
SDK_ROOT = os.path.join(FLUTTER_ROOT, "bin", "cache", "artifacts", "engine", "common", "flutter_patched_sdk_product")
PACKAGES = os.path.join(PROJ, ".dart_tool", "package_config.json")
FLUTTER_BAT = os.path.join(FLUTTER_ROOT, "bin", "flutter.bat")

DATA_API = "https://easy-learn-data-bunatimdzn.cn-hangzhou.fcapp.run"
AI_API = "https://easy-learn-ai-qutyqssdky.cn-hangzhou.fcapp.run"

# 与 build-cloud-apk.mjs / build-cloud-web.mjs 保持一致的 dart-defines
DART_DEFINES = (
    "REFUQV9BUElfQkFTRV9VUkw9aHR0cHM6Ly9lYXN5LWxlYXJuLWRhdGEtYnVuYXRpbWR6bi5jbi1oYW5nemhvdS5mY2FwcC5ydW4=,"
    "QUlfQkFTRV9VUkw9aHR0cHM6Ly9lYXN5LWxlYXJuLWFpLXF1dHlxc3Nka3kuY24taGFuZ3pob3UuZmNhcHAucnVu,"
    "RkxVVFRFUl9CVUlMRF9OQU1FPTEuMC4w,RkxVVFRFUl9CVUlMRF9OVU1CRVI9MQ==,"
    "RkxVVFRFUl9WRVJTSU9OPTMuNDcuMg==,RkxVVFRFUl9DSEFOTkVMPXN0YWJsZQ==,"
    "RkxVVFRFUl9HSVFfVVJMPWh0dHBzOi8vZ2l0aHViLmNvbS9mbHV0dGVyL2ZsdXR0ZXIuZ2l0,"
    "RkxVVFRFUl9GUkFNRVdPUktfUkVWSVNJT049ZDNiMTRjODc2OQ==,RkxVVFRFUl9FTkdJTkVfUkVWSVNJT049YTgwNGIyNjE2NA==,"
    "RkxVVFRFUl9EQVJUX1ZFUlNJT049My4xMy4y"
)

WORKDIR = os.path.join(PROJ, ".dart_tool", "flutter_build", "pybypass")


def run(cmd, timeout=1800, **kw):
    return subprocess.run(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, **kw)


def step(msg):
    print(f"\n===== {msg} =====", flush=True)


def compile_kernel_android():
    """frontend_server 编译 kernel -> app.dill（Android AOT）"""
    step("APK Step 1: frontend_server 编译 kernel")
    os.makedirs(WORKDIR, exist_ok=True)
    dill = os.path.join(WORKDIR, "app.dill")
    registrant = os.path.join(PROJ, ".dart_tool", "flutter_build", "dart_plugin_registrant.dart")
    cmd = [
        DARTAOTRUNTIME, FRONTEND_SERVER,
        f"--sdk-root={SDK_ROOT}/", "--target=flutter", "--no-print-incremental-dependencies",
        f"-DDATA_API_BASE_URL={DATA_API}", f"-DAI_BASE_URL={AI_API}",
        "-DFLUTTER_BUILD_NAME=1.0.0", "-DFLUTTER_BUILD_NUMBER=1",
        "-DFLUTTER_VERSION=3.47.2", "-DFLUTTER_CHANNEL=stable",
        "-DFLUTTER_GIQ_URL=https://github.com/flutter/flutter.git",
        "-DFLUTTER_FRAMEWORK_REVISION=d3b14c8769", "-DFLUTTER_ENGINE_REVISION=a804b26164",
        "-DFLUTTER_DART_VERSION=3.13.2", "-DFLUTTER_APP_FLAVOR=",
        "-Ddart.vm.profile=false", "-Ddart.vm.product=true",
        "--delete-tostring-package-uri=dart:ui", "--delete-tostring-package-uri=package:flutter",
        "--aot", "--tfa", "--target-os", "android",
        f"--packages={PACKAGES}", f"--output-dill={dill}",
        f"--depfile={os.path.join(WORKDIR, 'kernel_snapshot_program.d')}",
        f"--source=file:///{registrant.replace(chr(92), '/')}",
        "--source=package:flutter/src/dart_plugin_registrant.dart",
        f"-Dflutter.dart_plugin_registrant=file:///{registrant.replace(chr(92), '/')}",
        "--verbosity=error", "package:easy_learn_app/main.dart",
    ]
    r = run(cmd)
    if r.returncode != 0 or not os.path.exists(dill) or os.path.getsize(dill) < 1000000:
        print("FAILED kernel compile. rc=", r.returncode, "stderr=", (r.stderr or b'')[-800:].decode('utf-8', 'replace'))
        sys.exit(1)
    print(f"OK app.dill size={os.path.getsize(dill)}")
    return dill


def gen_snapshot_android(dill):
    """gen_snapshot 编译三架构 app.so"""
    step("APK Step 2: gen_snapshot 编译三架构 app.so")
    archs = {
        "arm64-v8a": (os.path.join(FLUTTER_ROOT, "bin/cache/artifacts/engine/android-arm64-release/windows-x64/gen_snapshot.exe"), []),
        "armeabi-v7a": (os.path.join(FLUTTER_ROOT, "bin/cache/artifacts/engine/android-arm-release/windows-x64/gen_snapshot.exe"),
                        ["--no-sim-use-hardfp", "--no-use-integer-division"]),
        "x86_64": (os.path.join(FLUTTER_ROOT, "bin/cache/artifacts/engine/android-x64-release/windows-x64/gen_snapshot.exe"), []),
    }
    out_so = {}
    for arch, (gs, extra) in archs.items():
        out = os.path.join(WORKDIR, arch, "app.so")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        cmd = [gs, "--deterministic", "--snapshot_kind=app-aot-elf", f"--elf={out}"] + extra + [dill]
        r = run(cmd, timeout=900)
        if r.returncode != 0 or not os.path.exists(out):
            print(f"FAILED gen_snapshot {arch}. rc={r.returncode}")
            sys.exit(1)
        out_so[arch] = out
        print(f"OK {arch} app.so size={os.path.getsize(out)}")
    return out_so


def patch_flutter_bat(intercept=True):
    """临时改写 flutter.bat：拦截 assemble 子命令（返回成功），其余透传。"""
    orig = FLUTTER_BAT + ".orig-231"
    if intercept:
        if not os.path.exists(orig):
            shutil.copy2(FLUTTER_BAT, orig)
        with open(FLUTTER_BAT, "w", encoding="utf-8") as f:
            f.write(
                "@ECHO OFF\r\n"
                "REM 231-bypass: intercept assemble only\r\n"
                "SETLOCAL\r\n"
                "SET FLUTTER_ROOT=%~dp0..\r\n"
                "SET _ARGS=%*\r\n"
                "SET HAS_ASSEMBLE=0\r\n"
                "ECHO %_ARGS% | findstr /I /C:\"assemble\" >nul && SET HAS_ASSEMBLE=1\r\n"
                "IF \"%HAS_ASSEMBLE%\"==\"1\" (ECHO [231-bypass] assemble intercepted & EXIT /B 0)\r\n"
                "SET shared_bin=%FLUTTER_ROOT%\\bin\\internal\\shared.bat\r\n"
                "CALL \"%shared_bin%\"\r\n"
                "SET flutter_tools_dir=%FLUTTER_ROOT%\\packages\\flutter_tools\r\n"
                "SET cache_dir=%FLUTTER_ROOT%\\bin\\cache\r\n"
                "SET snapshot_path=%cache_dir%\\flutter_tools.snapshot\r\n"
                "SET dart_sdk_path=%cache_dir%\\dart-sdk\r\n"
                "SET dart=%dart_sdk_path%\\bin\\dart.exe\r\n"
                "SET exit_with_errorlevel=%FLUTTER_ROOT%/bin/internal/exit_with_errorlevel.bat\r\n"
                "\"%dart%\" --packages=\"%flutter_tools_dir%\\.dart_tool\\package_config.json\" %FLUTTER_TOOL_ARGS% \"%snapshot_path%\" %* & \"%exit_with_errorlevel%\"\r\n"
            )
    else:
        if os.path.exists(orig):
            shutil.copy2(orig, FLUTTER_BAT)
            os.remove(orig)


def gradle_assemble():
    """拦截 assemble 后 Python 直调 gradlew 打包 APK"""
    step("APK Step 4: gradle assembleRelease（assemble 已拦截）")
    intermediate = os.path.join(PROJ, "build", "app", "intermediates", "flutter", "release")
    future = time.time() + 100000
    targets = [
        os.path.join(intermediate, "arm64-v8a", "app.so"),
        os.path.join(intermediate, "armeabi-v7a", "app.so"),
        os.path.join(intermediate, "x86_64", "app.so"),
        os.path.join(intermediate, "flutter_assets", "AssetManifest.bin"),
        os.path.join(intermediate, "flutter_assets", "FontManifest.json"),
        os.path.join(intermediate, "flutter_assets", "NOTICES.Z"),
        os.path.join(intermediate, "flutter_assets", "NativeAssetsManifest.json"),
        os.path.join(intermediate, "flutter_assets", "fonts", "MaterialIcons-Regular.otf"),
        os.path.join(intermediate, "flutter_assets", "packages", "cupertino_icons", "assets", "CupertinoIcons.ttf"),
        os.path.join(intermediate, "flutter_assets", "shaders", "ink_sparkle.frag"),
        os.path.join(intermediate, "flutter_assets", "shaders", "stretch_effect.frag"),
    ]
    for t in targets:
        if os.path.exists(t):
            os.utime(t, (future, future))
    os.utime(os.path.join(intermediate, "flutter_build.d"), (future, future))

    gcmd = [
        os.path.join(PROJ, "android", "gradlew.bat"),
        "-Ptarget-platform=android-arm,android-arm64,android-x64",
        r"-Ptarget=lib\main.dart",
        "-Pbase-application-name=android.app.Application",
        f"-Pdart-defines={DART_DEFINES}",
        "-Pdart-obfuscation=false", "-Ptrack-widget-creation=true", "-Ptree-shake-icons=false",
        r"-Pflutter.androidSdkRoot=C:\dev\android-sdk",
        "-Pflutter.installedNdkVersions=28.2.13676358",
        r"-Pflutter.sdkManagerPath=C:\dev\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat",
        "assembleRelease",
    ]
    r = run(gcmd, cwd=os.path.join(PROJ, "android"), timeout=1800)
    txt = (r.stdout or b'').decode('utf-8', 'replace')
    print("gradle returncode:", r.returncode)
    if r.returncode != 0:
        print(txt[-3000:])
        sys.exit(1)
    print("BUILD SUCCESSFUL")


def build_apk():
    patch_flutter_bat(intercept=True)
    try:
        dill = compile_kernel_android()
        out_so = gen_snapshot_android(dill)
        step("APK Step 3: 放置 app.so")
        intermediate = os.path.join(PROJ, "build", "app", "intermediates", "flutter", "release")
        for arch, src in out_so.items():
            shutil.copy2(src, os.path.join(intermediate, arch, "app.so"))
        gradle_assemble()
    finally:
        patch_flutter_bat(intercept=False)
    apk = os.path.join(PROJ, "build", "app", "outputs", "flutter-apk", "app-release.apk")
    print(f"\n===== APK: {apk} size={os.path.getsize(apk)} mtime={time.ctime(os.path.getmtime(apk))} =====")


def build_web():
    step("Web Step 1: dart2js 两阶段编译")
    # 找 web 的 hash 目录（含 main.dart 入口的）
    fb = os.path.join(PROJ, ".dart_tool", "flutter_build")
    hashdir = None
    for d in os.listdir(fb):
        p = os.path.join(fb, d)
        if os.path.isdir(p) and os.path.exists(os.path.join(p, "main.dart")) and os.path.exists(os.path.join(p, "main.dart.js")):
            # 选最新的
            if hashdir is None or os.path.getmtime(p) > os.path.getmtime(hashdir):
                hashdir = p
    if hashdir is None:
        print("FAILED: 找不到含 main.dart 入口的 web build 目录")
        sys.exit(1)
    main_dart = os.path.join(hashdir, "main.dart")
    app_dill = os.path.join(hashdir, "app.dill")
    main_js = os.path.join(hashdir, "main.dart.js")

    platform_bin = os.path.join(FLUTTER_ROOT, "bin/cache/flutter_web_sdk/kernel")
    shared = [
        f"--platform-binaries={platform_bin}", "--invoker=flutter_tool",
        "-Ddart.vm.product=true",
        f"-DDATA_API_BASE_URL={DATA_API}", f"-DAI_BASE_URL={AI_API}",
        "-DFLUTTER_BUILD_NAME=1.0.0", "-DFLUTTER_BUILD_NUMBER=1",
        "-DFLUTTER_VERSION=3.47.2", "-DFLUTTER_CHANNEL=stable",
        "-DFLUTTER_GIT_URL=https://github.com/flutter/flutter.git",
        "-DFLUTTER_FRAMEWORK_REVISION=d3b14c8769", "-DFLUTTER_ENGINE_REVISION=a804b26164",
        "-DFLUTTER_DART_VERSION=3.13.2",
        "-DFLUTTER_WEB_USE_SKIA=true", "-DFLUTTER_WEB_USE_SKWASM=false",
        "-DFLUTTER_WEB_CANVASKIT_URL=https://www.gstatic.com/flutter-canvaskit/a804b261645ef8c13eb3d5c44a5c2fb0340c5539/",
        "--write-resources", "--enable-experiment=record-use",
        "--native-null-assertions", "--no-source-maps", "-O4", "--minify",
    ]
    r = run([DARTAOTRUNTIME, DART2JS] + shared + ["-o", app_dill, f"--packages={PACKAGES}", "--cfe-only", main_dart])
    if r.returncode != 0:
        print("cfe FAILED:", (r.stderr or b'')[-1500:].decode('utf-8', 'replace'))
        sys.exit(1)
    print("cfe OK app.dill size=", os.path.getsize(app_dill))
    r = run([DARTAOTRUNTIME, DART2JS] + shared + ["-o", main_js, app_dill])
    if r.returncode != 0:
        print("js FAILED:", (r.stderr or b'')[-1500:].decode('utf-8', 'replace'))
        sys.exit(1)
    print("js OK main.dart.js size=", os.path.getsize(main_js))

    step("Web Step 2: 覆盖 build/web/main.dart.js")
    web_main_js = os.path.join(PROJ, "build", "web", "main.dart.js")
    shutil.copy2(main_js, web_main_js)
    print(f"OK {web_main_js} size={os.path.getsize(web_main_js)}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    if target in ("apk", "all"):
        build_apk()
    if target in ("web", "all"):
        build_web()
    print("\n完成。")
