plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")         // ← use the org.jetbrains id in Kotlin DSL
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.passkey_mobile_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.14033849"               // or "27.0.12077973" if you pinned 27

    defaultConfig {
        applicationId = "com.example.passkey_mobile_app"
        minSdk = flutter.minSdkVersion
        // ✅ FIX: use targetSdk (property), not targetSdkVersion =
        // If this line fails to resolve, replace with: targetSdk = 34
        targetSdk = flutter.targetSdkVersion

        versionCode = 1
        versionName = "1.0"
        multiDexEnabled = true
    }

    // Use Java 17 with recent AGP/Flutter templates
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
        release {
            // Debug signing so `flutter run --release` works in dev
            signingConfig = signingConfigs.getByName("debug")
            // If you want resource shrinking in release, minify must be on:
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

flutter {
    source = "../.."
}
