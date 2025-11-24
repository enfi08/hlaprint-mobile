########## PDFBOX ##########
-keep class com.tom_roush.pdfbox.** { *; }
-dontwarn com.tom_roush.pdfbox.**

-keep class org.apache.pdfbox.** { *; }
-dontwarn org.apache.pdfbox.**

-keep class org.apache.fontbox.** { *; }
-dontwarn org.apache.fontbox.**

########## JP2 (jika masih pakai) ##########
-keep class com.gemalto.jp2.** { *; }
-dontwarn com.gemalto.jp2.**

########## IPP ##########
-keep class de.gmuth.ipp.** { *; }
-dontwarn de.gmuth.ipp.**

########## FLUTTER EMBEDDING v2 ##########
# KEEP embedding v2 ONLY
-keep class io.flutter.embedding.** { *; }

########## MAINACTIVITY (WAJIB UNTUK METHODCHANNEL) ##########
-keep class com.hlaprint.app.MainActivity { *; }

########## ANDROIDX ##########
-keep class androidx.lifecycle.** { *; }
-keep class * extends androidx.lifecycle.ViewModel { *; }

########## JANGAN KEEP V1 FLUTTER (HAPUS) ##########
# -keep class io.flutter.view.** { *; }   <-- REMOVE
# -keep class io.flutter.plugin.** { *; } <-- REMOVE
# -keep class io.flutter.app.** { *; }    <-- REMOVE

########## JANGAN KEEP APPLICATION YANG TIDAK ADA ##########
# -keep public class com.hlaprint.app.Application { *; } <-- REMOVE
