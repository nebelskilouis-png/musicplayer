// Uhr-App (Wear OS) – eigenes Gradle-Projekt, unabhängig von Flutter.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
plugins {
    id("com.android.application") version "9.3.1" apply false
}
rootProject.name = "musicplayer-wear"
include(":app")
