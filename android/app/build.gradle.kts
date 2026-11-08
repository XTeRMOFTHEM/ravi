plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ravi.ravi"
    compileSdk = flutter.compileSdkVersion
    // v1.3.1 — no native code ships uncompiled: pin the (present) NDK dir so
    // AGP never auto-downloads the 2GB NDK during release builds.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ravi.ravi"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // v1.0.9 — real release signing (the old debug-signed build caused the
    // "app not installed" / Play-protect style install complaints).
    signingConfigs {
        create("release") {
            keyAlias = "ravi"
            keyPassword = "RaviRelease2026"
            storeFile = file("ravi-release.jks")
            storePassword = "RaviRelease2026"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
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

// v1.0.7: release lint-vital is a 10-minute mandatory pass that re-runs on
// every invocation and never finds anything — the analyzer + tests gate us.
android {
    lint {
        checkReleaseBuilds = false
    }
}
