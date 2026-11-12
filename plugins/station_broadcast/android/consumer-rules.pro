# Consumer ProGuard/R8 rules for station_broadcast.
# Applied to any app that depends on this plugin so release (minified) builds
# keep the classes libpjsua2.so reaches by exact name via JNI.

# Keep the entire pjsua2 SWIG binding — classes AND members — unobfuscated.
-keep class org.pjsip.pjsua2.** { *; }
-keepclassmembers class org.pjsip.pjsua2.** { *; }

# Our SIP engine subclasses (Account/Call) are called back from native.
-keep class tv.stationcast.station_broadcast.** { *; }
-keepclassmembers class tv.stationcast.station_broadcast.** { *; }

# JNI: keep any native method signatures intact.
-keepclasseswithmembernames class * {
    native <methods>;
}

# BroadcastEngine uses reflection to set the physical microphone on StreamPack's
# AudioRecord source. Keep the field name stable in minified builds.
-keepclassmembers class io.github.thibaultbee.streampack.core.elements.sources.audio.audiorecord.AudioRecordSource {
    private android.media.AudioRecord audioRecord;
}
