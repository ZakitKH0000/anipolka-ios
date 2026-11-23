plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.zakitkh.anipolka"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.zakitkh.anipolka"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "1.3.0-android"
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildTypes {
        debug { isDebuggable = true }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Personal app: the release build is signed with the local debug key so it installs over USB.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    testOptions { unitTests { isReturnDefaultValues = false } }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    // Backdrop blur for the iOS-style glass tab bar and title bars (Android 12+; older versions get a tint).
    implementation("dev.chrisbanes.haze:haze:1.6.10")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub in local unit tests; the real library runs the core logic there.
    testImplementation("org.json:json:20240303")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
