import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hlaprint/screens/home_page.dart';
import 'package:hlaprint/screens/login_screen.dart';
import 'package:hlaprint/services/MyHttpOverrides.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:hlaprint/utils/migration_helper.dart';
import 'package:hlaprint/constants.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await performWindowsDataMigration();

  try {
    final prefs = await SharedPreferences.getInstance();
    bool isSslEnabled = prefs.getBool('ssl_enabled') ?? true;

    debugPrint("LOG: SSL Config: ${isSslEnabled ? 'ENABLED (Secure)' : 'DISABLED (Bypass)'}");

    if (!isSslEnabled) {
      HttpOverrides.global = MyHttpOverrides();
    }
  } catch (e) {
    debugPrint("LOG Error: $e");
  }

  await SentryFlutter.init(
        (options) {
      options.dsn = 'https://7022892b4c4313f2acf1b4bd43a0c7a7@o4508279105060864.ingest.de.sentry.io/4510219873812560';

      options.sendDefaultPii = true;
      options.enableAppHangTracking = false;
    },
    appRunner: () async {
      final prefs = await SharedPreferences.getInstance();
      String initialRoute = '/login';

      try {
        final savedUserId = prefs.getString(userIdKey);
        final savedName = prefs.getString(nameKey);
        final savedEmail = prefs.getString(emailKey);
        final authService = AuthService();
        final token = await authService.getToken();

        if (token != null) {
          initialRoute = '/home';
        }
        if (savedUserId != null || savedName != null || savedEmail != null) {
          Sentry.configureScope((scope) {
            scope.setUser(SentryUser(
              id: savedUserId,
              username: savedName,
              email: savedEmail,
            ));
          });
        }
      } catch (e, stackTrace) {
        debugPrint("ERROR INITIALIZATION: $e");
        await Sentry.captureException(e, stackTrace: stackTrace);
      }

      runApp(
        MyApp(initialRoute: initialRoute),
      );
    },
  );
}

class MyApp extends StatelessWidget {
  final String initialRoute;

  const MyApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hlaprint',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: initialRoute,
      routes: {
        '/login': (context) => LoginScreen(),
        '/home': (context) => HomePage(),
      },
    );
  }
}