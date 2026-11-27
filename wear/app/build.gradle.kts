plugins {
    id("com.android.application")
}

android {
    // Gleicher Paketname + gleiche Signatur wie die Handy-App -> nötig, damit Uhr und Handy sich finden
    namespace = "com.example.musicplayer"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.musicplayer"
        minSdk = 30
        targetSdk = 35
        versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = "1.0"
    }

    signingConfigs {
        getByName("debug") {
            val ci = rootProject.file("ci-debug.keystore")
            if (ci.exists()) {
                storeFile = ci
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    implementation("androidx.media3:media3-session:1.8.0")
    implementation("androidx.core:core:1.16.0")
}
