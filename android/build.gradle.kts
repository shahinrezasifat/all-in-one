allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }

    // AGP 9.x ships lint tooling compiled for newer JDK APIs; the lint-vital
    // tasks crash on some JDKs (NoSuchMethodError: List.removeLast) inside
    // third-party plugin modules. Lint is not part of the shipped APK and can
    // still be run explicitly on a supported toolchain.
    tasks.matching { it.name.startsWith("lint") }.configureEach {
        enabled = false
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
