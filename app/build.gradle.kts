plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.studyvault.tv"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.studyvault.tv"
        minSdk = 21          // Android 5.0，覆盖老电视盒子
        targetSdk = 34       // 兼容到最新版安卓
        versionCode = 1
        versionName = "1.0.0"
        multiDexEnabled = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // 用 debug 签名，保证 CI 产出的 APK 可以直接装到电视上测试
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        // jcifs-ng 等库用到 Java 8 时间/流 API，安卓 5 上必须开启脱糖
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildFeatures {
        viewBinding = true
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt",
                "META-INF/ASL2.0",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/versions/9/module-info.class",
                "module-info.class"
            )
        }
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

dependencies {
    // 脱糖库：让 Java 8 API 在 Android 5 上可用
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.activity:activity-ktx:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // 播放内核：1.4.1 是 minSdk 21 友好版本（1.9.0+ 起要求安卓 6.0）
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")

    // WebDAV 走 HTTP，用 OkHttp 做 PROPFIND 与分段读取
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // SMB 客户端（纯 Java，兼容安卓 5；smbj 因用到 API26 特性无法在安卓5上运行）
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10")
    implementation("org.slf4j:slf4j-nop:1.7.36")
}
