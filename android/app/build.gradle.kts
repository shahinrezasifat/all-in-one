import java.util.Properties
import java.io.FileInputStream
import com.android.build.api.dsl.LibraryExtension

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The app uses the platform video player on Android. Avoid shipping
// its MDK FFmpeg library under the same name as yt-dlp's FFmpeg executable.
project.findProject(":fvp")?.plugins?.withId("com.android.library") {
    project(":fvp").extensions.configure<LibraryExtension> {
        packaging.jniLibs.excludes.add("**/libffmpeg.so")
    }
}

// Market signing: android/key.properties holds the release keystore details.
// A release APK must never silently fall back to the debug key — such a build
// can not be updated over the air on a user's device.
val keystoreProperties = Properties()
val releaseAbi = providers.gradleProperty("release-abi").orNull
if (releaseAbi != null) {
    require(releaseAbi in setOf("arm64-v8a", "armeabi-v7a", "x86_64"))
}
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.snaptube.pure.snaptube_pure"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.snaptube.pure.snaptube_pure"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ytdlp_flutter (youtubedl-android) requires API 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Keep the same version code for universal and ABI-specific APKs.
        if (releaseAbi != null) {
            ndk.abiFilters.add(releaseAbi)
        }
    }

    packaging {
        jniLibs {
            // youtubedl-android needs its libs extracted at runtime.
            useLegacyPackaging = true
            // youtubedl-android ships compressed payloads as *.zip.so — not ELF.
            doNotStrip += listOf("**/*.zip.so")
        }
    }

    buildTypes {
        release {
            // Signed with the permanent upload key when available; a debug-key
            // APK could never be updated over the air (users would have to
            // uninstall and lose every download reference).
            signingConfig = if (keystorePropertiesFile.exists() &&
                file(keystoreProperties["storeFile"] as String).exists()
            ) {
                signingConfigs.create("release").apply {
                    keyAlias = keystoreProperties["keyAlias"] as String
                    keyPassword = keystoreProperties["keyPassword"] as String
                    storeFile = file(keystoreProperties["storeFile"] as String)
                    storePassword = keystoreProperties["storePassword"] as String
                }
            } else {
                error(
                    "Release signing key is missing. Create android/key.properties " +
                        "and the release keystore, or build a debug APK instead."
                )
            }
            // R8 code shrinking renames kotlin.coroutines.Continuation, which
            // breaks the dart:jni / Pigeon bridge: shared_preferences (and other
            // plugins) look Java methods up by their fixed JVM descriptor, e.g.
            // getAll(Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/
            // Continuation;)Ljava/lang/Object;. After the rename the descriptor
            // no longer matches and every prefs call throws NoSuchMethodError,
            // silently disabling all persistence (downloads, watch-history,
            // settings, vault, preferences). Keep shrinking off for a correct APK.
            isMinifyEnabled = false
            isShrinkResources = false
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
    implementation("androidx.media3:media3-exoplayer:1.9.2")
    implementation("com.github.recloudstream.cloudstream:library:v4.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}
