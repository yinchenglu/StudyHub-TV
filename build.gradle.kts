// 顶层构建脚本：只声明插件版本，具体配置在各模块的 build.gradle.kts 中
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
