import java.io.File

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Build outputs live on the large external volume (small rootfs disk).
val newBuildDir: File = File("/tmp/my-project/ravi_build")
rootProject.layout.buildDirectory.fileValue(newBuildDir)

subprojects {
    val newSubprojectBuildDir: File = File(newBuildDir, project.name)
    project.layout.buildDirectory.fileValue(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
