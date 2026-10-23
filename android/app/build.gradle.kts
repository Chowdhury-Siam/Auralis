import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = rootProject.file("key.properties")
val releaseKey = Properties().apply {
    if (signingFile.exists()) signingFile.inputStream().use { load(it) }
}

android {
    namespace = "app.auralis.auralis"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "app.auralis.auralis"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
            signingConfig = if (signingFile.exists()) signingConfigs.getByName("release") else null
        }
    }
    // Each workflow build packages one ABI; missing Telegram binaries fail early.
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }

dependencies {
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

tasks.register("verifyTdlib") {
    doLast {
        val platforms = (project.findProperty("target-platform") as String? ?: "android-arm64")
            .split(",").map {
                when (it) {
                    "android-arm64" -> "arm64-v8a"
                    "android-x64" -> "x86_64"
                    else -> error("Unsupported Android ABI: $it. Build android-arm64 or android-x64.")
                }
            }
        platforms.forEach {
            check(file("src/main/jniLibs/$it/libtdjson.so").isFile) {
                "Missing TDLib for $it. Run bash tool/build-tdlib-android.sh $it first."
            }
        }
    }
}
tasks.named("preBuild") { dependsOn("verifyTdlib") }
tasks.matching { it.name in setOf("validateSigningRelease", "packageRelease", "assembleRelease", "signReleaseBundle") }.configureEach {
    doFirst { check(signingFile.exists()) { "Release builds require android/key.properties. See docs/ANDROID.md." } }
}
