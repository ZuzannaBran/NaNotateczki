import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties()
val releaseKeyFile = rootProject.file("key.properties")
if (releaseKeyFile.isFile) {
    releaseKeyFile.inputStream().use { releaseKeys.load(it) }
}

val requiredReleaseKeys = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
val signingValuesPresent = requiredReleaseKeys.any {
    !releaseKeys.getProperty(it).isNullOrBlank()
}
val completeReleaseKeys = requiredReleaseKeys.all {
    !releaseKeys.getProperty(it).isNullOrBlank()
}

if (releaseKeyFile.exists() && !completeReleaseKeys) {
    throw GradleException(
        "android/key.properties is incomplete. Required keys: " +
            requiredReleaseKeys.joinToString(", "),
    )
}
if (signingValuesPresent && !completeReleaseKeys) {
    throw GradleException("Incomplete Android release signing credentials.")
}
if (completeReleaseKeys &&
    !rootProject.file(releaseKeys.getProperty("storeFile")).isFile
) {
    throw GradleException("Android release keystore file does not exist.")
}

val debugReleaseAllowed =
    System.getenv("CI")?.equals("true", ignoreCase = true) == true ||
        System.getenv("NANOTATECZKI_ALLOW_DEBUG_RELEASE_SIGNING") == "true"
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true) ||
        it.contains("bundle", ignoreCase = true)
}
if (releaseTaskRequested && !completeReleaseKeys && !debugReleaseAllowed) {
    throw GradleException(
        "Release signing is not configured. Set up android/key.properties " +
            "with a private keystore; only CI or an explicit " +
            "NANOTATECZKI_ALLOW_DEBUG_RELEASE_SIGNING=true may build a " +
            "debug-signed release for testing.",
    )
}


android {
    namespace = "com.example.program"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.program"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (completeReleaseKeys) {
            create("release") {
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (completeReleaseKeys) {
                signingConfigs.getByName("release")
            } else {
                // For CI compilation only; a publishable release needs keys.
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
