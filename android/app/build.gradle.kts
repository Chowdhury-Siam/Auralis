import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

val targetPlatform = (findProperty("target-platform") as? String) ?: "android-arm64"
val targetAbi = when (targetPlatform) {
    "android-arm64" -> "arm64-v8a"
    "android-x64" -> "x86_64"
    else -> error("Build one Android target with --target-platform android-arm64 or android-x64.")
}
val abiVersionOffset = if (targetAbi == "arm64-v8a") 2000 else 4000

val signingFile = rootProject.file("key.properties")
val releaseKey = Properties().apply {
    if (signingFile.exists()) signingFile.inputStream().use { load(it) }
}

android {
    namespace = "com.auralis.siam"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.auralis.siam"
        minSdk = 24
        targetSdk = 36
        // Match the version codes used by Flutter's previous ABI splits so installed APKs can upgrade.
        versionCode = flutter.versionCode + abiVersionOffset
        versionName = flutter.versionName
        ndk.abiFilters.add(targetAbi)
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    if (signingFile.exists()) {
        signingConfigs.create("release") {
            storeFile = rootProject.file(releaseKey.getProperty("storeFile"))
            storePassword = releaseKey.getProperty("storePassword")
            keyAlias = releaseKey.getProperty("keyAlias")
            keyPassword = releaseKey.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            signingConfig = if (signingFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    // QuickJS is an executable in nativeLibraryDir, which requires extraction.
    packaging.jniLibs.useLegacyPackaging = true
    // Each workflow build packages one ABI; missing Telegram binaries fail early.
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
chaquopy {
    defaultConfig {
        version = "3.13"
        pip {
            install("yt-dlp==2026.10.26")
            install("yt-dlp-ejs==0.8.0")
        }
    }
}

dependencies {
    implementation("androidx.core:core:1.17.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

tasks.register("verifyTdlib") {
    doLast {
        check(file("src/main/jniLibs/$targetAbi/libtdjson.so").isFile) {
            "Missing TDLib for $targetAbi. Run bash tool/build-tdlib-android.sh $targetAbi first."
        }
    }
}
tasks.named("preBuild") { dependsOn("verifyTdlib") }
