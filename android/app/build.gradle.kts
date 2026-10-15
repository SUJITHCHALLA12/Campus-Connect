import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: CI restores android/app/release.keystore from
// the KEYSTORE_BASE64 secret and writes key.properties from the
// KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD secrets. Local
// builds without key.properties fall back to the debug key, so
// `flutter run --release` keeps working.
//
// The stable release signature is what makes updates install over
// the old app (same signature) instead of forcing an uninstall —
// which is what preserves chats, groups and identity across
// updates. Never commit the keystore or key.properties.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sujithchalla.campusconnect"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.sujithchalla.campusconnect"
        // bluetooth_low_energy requires minSdk 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Only read when key.properties exists (CI); otherwise
            // this config stays unset and buildTypes uses debug.
            // getProperty returns String — no casts needed.
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword =
                    keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Stable release signature when key.properties exists (CI);
            // otherwise the standard debug config for local builds.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
