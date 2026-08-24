# Android Controller

The Android controller uses Kotlin and Jetpack Compose for product UI. Upstream
WebRTC renderers remain Android Views hosted through Compose interoperability;
platform audio, foreground service, PiP, storage, and credential lifecycles stay
Android-owned.

The Gradle application is added after the shared contracts and controller
identity API are stable enough for the physical-device media spike. It will use
a checked-in Gradle wrapper and will not require a global Gradle installation.
