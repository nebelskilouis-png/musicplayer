allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Alle Plugins mit mindestens Android-API 36 bauen.
// Manche Plugins (z.B. file_picker) sind noch auf 34 eingestellt -> sonst Build-Fehler
// "requires ... compile against version 36 or later".
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        try {
            android.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType).invoke(android, 36)
        } catch (e: Exception) {
            try {
                android.javaClass.getMethod("setCompileSdk", java.lang.Integer::class.java).invoke(android, 36)
            } catch (e2: Exception) {
                println("compileSdk konnte für ${project.name} nicht gesetzt werden: ${e2.message}")
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
