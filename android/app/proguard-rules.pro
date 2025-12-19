-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

-keep class dev.flutter.pigeon.** { *; }
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }
-keepnames class dev.flutter.pigeon.** { *; }
-keepclassmembers class dev.flutter.pigeon.** { *; }

-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }

-keepattributes SourceFile,LineNumberTable,EnclosingMethod,*Annotation*,Signature,InnerClasses

-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }

-keep class com.tom_roush.pdfbox.** { *; }
-dontwarn com.tom_roush.pdfbox.**
-keep class org.apache.pdfbox.** { *; }
-dontwarn org.apache.pdfbox.**
-keep class org.apache.fontbox.** { *; }
-dontwarn org.apache.fontbox.**
-keep class com.gemalto.jp2.** { *; }
-dontwarn com.gemalto.jp2.**
-keep class de.gmuth.ipp.** { *; }
-dontwarn de.gmuth.ipp.**
-keep class io.flutter.embedding.** { *; }
-keep class com.hlaprint.app.MainActivity { *; }
-keep class androidx.lifecycle.** { *; }
-keep class * extends androidx.lifecycle.ViewModel { *; }