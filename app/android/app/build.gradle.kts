import java.io.FileInputStream
import java.util.Properties

// Friends' builds are signed with the project's own release key when BUDDY_SIGNING names its key.properties
// (kept outside every repository: storeFile, storePassword, keyAlias, keyPassword). Without it the release
// build stays on the debug key, as the personal build always has, so a phone that has it keeps updating.
val buddySigning: File? = System.getenv("BUDDY_SIGNING")?.let { file(it) }?.takeIf { it.exists() }

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.rakasaka.ensh_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rakasaka.ensh_companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (buddySigning != null) {
            create("buddy") {
                val p = Properties().apply { FileInputStream(buddySigning).use { load(it) } }
                storeFile = file(p.getProperty("storeFile"))
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (buddySigning != null) signingConfigs.getByName("buddy") else signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // QR pairing (MainActivity, channel "ensh/scan"): Google's scanner, no camera permission
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
