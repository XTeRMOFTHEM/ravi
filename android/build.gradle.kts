import java.io.File

allprojects {
    repositories {
        // v1.2.0 — aliyun mirrors first (repo1.maven.org rate-limits = HTTP 429)
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

// Build outputs default to the project's build/ dir (fast local disk).
// The v1.3.1 /tmp redirect was for an environment whose rootfs was tiny;
// this sandbox has ~4GB free locally while its gradle caches live on the
// big external volume via GRADLE_USER_HOME.



// v1.4.0 — optional build-dir redirect for constrained sandboxes:
// export RAVI_BUILD_DIR=/path/to/build  (leave unset on normal machines)
val _raviBuildDir = System.getenv("RAVI_BUILD_DIR")
if (!_raviBuildDir.isNullOrBlank()) {
    rootProject.layout.buildDirectory.set(file("$_raviBuildDir/root"))
    subprojects {
        layout.buildDirectory.set(file("$_raviBuildDir/${project.name}"))
    }
}

subprojects {
    // v1.3.2 — mirror-first BUILDSCRIPT repos: plugin subprojects (audioplayers
    // etc.) declare their own buildscript repos (mavenCentral) that were being
    // HTTP-429-rate-limited; this block runs BEFORE their buildscript blocks,
    // so the aliyun mirrors resolve first and mavenCentral is only a fallback.
    buildscript {
        repositories {
            maven("https://maven.aliyun.com/repository/gradle-plugin")
            maven("https://maven.aliyun.com/repository/public")
            maven("https://maven.aliyun.com/repository/google")
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
