import 'dart:io';
import 'package:flutter/material.dart';
import 'package:Hlaprint/screens/home_page.dart';
import 'package:Hlaprint/screens/login_screen.dart';
import 'package:Hlaprint/services/MyHttpOverrides.dart';
import 'package:Hlaprint/services/auth_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  HttpOverrides.global = MyHttpOverrides();

  await SentryFlutter.init(
        (options) {
      options.dsn = 'https://7022892b4c4313f2acf1b4bd43a0c7a7@o4508279105060864.ingest.de.sentry.io/4510219873812560';

      options.sendDefaultPii = true;
      options.enableAppHangTracking = false;
    },
    appRunner: () async {
      String initialRoute = '/login';

      try {
        final authService = AuthService();
        final token = await authService.getToken();

        if (token != null) {
          initialRoute = '/home';
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