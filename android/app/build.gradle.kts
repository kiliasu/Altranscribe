import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties (ignored by Git) supplies the release signing key.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}

android {
    namespace = "app.altranscribe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.altranscribe"
        minSdk = 29
        ndk { abiFilters += "arm64-v8a" }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake { arguments += "-DANDROID_STL=c++_shared" }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/audioAssets").get().asFile)

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Without key.properties, local release builds keep the debug key so they
            // stay installable over each other; see docs/CONTRIBUTING.md, Distribution.
            signingConfig = if (keystorePropertiesFile.exists()) {
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

dependencies {
    // The pairing QR scanner: CameraX for the preview and ZXing to decode frames.
    val camerax = "1.4.2"
    implementation("androidx.activity:activity:1.9.3")
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("com.google.zxing:core:3.5.3")
}

val audioAssets by tasks.registering(Copy::class) {
    from("../../native/third_party/rnnoise/rnnoise-model.bin")
    from("../../native/third_party/rnnoise/COPYING") { into("licenses"); rename { "RNNoise-LICENSE" } }
    from("../../native/third_party/speex/COPYING") { into("licenses"); rename { "SpeexDSP-LICENSE" } }
    from("../../.tools/ffmpeg-android/ffmpeg-8.1.2/COPYING.LGPLv2.1") { into("licenses"); rename { "FFmpeg-LICENSE" } }
    into(layout.buildDirectory.dir("generated/audioAssets"))
}
tasks.named("preBuild").configure { dependsOn(audioAssets) }
