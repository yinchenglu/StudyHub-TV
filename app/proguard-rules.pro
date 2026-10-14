# jcifs-ng / BouncyCastle 依赖大量反射与 SPI，保留其类名
-keep class jcifs.** { *; }
-dontwarn jcifs.**
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn org.slf4j.**
-dontwarn javax.**
-dontwarn java.awt.**

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**

# Media3
-dontwarn androidx.media3.**
