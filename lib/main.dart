
import 'package:flutter/material.dart';
import 'package:hlaprint/screens/home_page.dart';
import 'package:hlaprint/screens/login_screen.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final authService = AuthService();
  final token = await authService.getToken();
  final String initialRoute = token != null ? '/home' : '/login';
  await SentryFlutter.init(
        (options) {
      options.dsn = 'https://7022892b4c4313f2acf1b4bd43a0c7a7@o4508279105060864.ingest.de.sentry.io/4510219873812560';

      options.sendDefaultPii = true;
    },
    appRunner: () => runApp(
      MyApp(initialRoute: initialRoute),
    ),
  );
}

class MyApp extends StatelessWidget {
  final String initialRoute;

  const MyApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hlaprint Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: initialRoute,
      routes: {
        '/login': (context) => LoginScreen(),
        '/home': (context) => HomePage(),
      },
    );
  }
}

