import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/**
 * 发布签名（见 `doc/release-guide.md` §1）。
 *
 * `android/key.properties` **不入库**（里面是 keystore 的明文密码），
 * 用 `build/_make-keystore.mjs` 生成，或照文档里的 `keytool` 命令自己来。
 *
 * 两种签名的区别不是「规范问题」，是三个具体后果：
 *   · debug 签名的包**上不了架**；
 *   · debug key 是**跟机器走**的 —— 换台电脑构建出的包签名不同，
 *     装过旧包的手机必须**先卸载**才能装新的（数据一起没）；
 *   · 真 release 签名一旦用于上架，就**必须永久保管**：换了签名商店拒收更新，
 *     丢了它那个应用就再也更新不了了。
 *
 * 所以这里的行为是：**有 key.properties 就用它；没有就回退 debug 签名，
 * 但只要这一次构建的任务名里有 Release，就在日志里大声警告**。
 * 回退是为了让没配密钥的机器照样能 `flutter run --release`（开发需要），
 * 警告是为了让「打了个假 release 包」这件事**不可能安静发生**。
 */
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

/** 这次构建是不是在要 release 产物（任务名里带 Release 就算）。 */
val wantsRelease = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }

if (wantsRelease && !hasReleaseSigning) {
    logger.warn(
        "\n⚠️  这次是 release 构建，但找不到 android/key.properties —— **正在用 debug key 签名**。\n" +
        "    这个包：不能上架；换台机器构建出来的签名不同，装过旧包的手机必须卸载才能装。\n" +
        "    生成发布签名：node build/_make-keystore.mjs（或照 doc/release-guide.md §1 用 keytool）。\n"
    )
}

android {
    namespace = "cn.easylearn.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用身份，上架后**不能改**（改了 = 换一个应用，商店不认、旧版装不上升级包）。
        applicationId = "cn.easylearn.app.local"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile 相对于**本模块**（android/app）解析，所以 key.properties 里
                // 写的是 `release-keystore.p12` 这样的文件名，不是绝对路径 ——
                // 绝对路径换台机器就指向别人家去了，而这种错**不会报错，只会签错**。
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
