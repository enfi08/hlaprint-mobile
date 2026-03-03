import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SplashScreen extends StatefulWidget {
  final String targetRoute;

  const SplashScreen({super.key, required this.targetRoute});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _lottieController;
  String _version = '';
  bool _showAppName = false;
  bool _showVersion = false;

  @override
  void initState() {
    super.initState();
    _lottieController = AnimationController(vsync: this);
    _getAppVersion();
  }

  Future<void> _getAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _version = 'v${packageInfo.version}';
    });
  }

  @override
  void dispose() {
    _lottieController.dispose();
    super.dispose();
  }

  void _startTextAnimationSequence() async {
    // 1. Lottie selesai, munculkan Nama Aplikasi (Zoom-in)
    setState(() {
      _showAppName = true;
    });

    // 2. Tunggu sebentar (400ms), lalu munculkan Teks Versi (Zoom-in)
    await Future.delayed(const Duration(milliseconds: 400));
    setState(() {
      _showVersion = true;
    });

    // 3. Tunggu 2 detik agar user bisa membaca, lalu pindah halaman
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      Navigator.of(context).pushReplacementNamed(widget.targetRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        // Menggunakan Column agar posisi tepat berurutan dari atas ke bawah
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 1. Animasi Lottie (Tetap dipertahankan, tidak menghilang)
            Lottie.asset(
              'assets/animations/splash_screen.json',
              controller: _lottieController,
              fit: BoxFit.contain,
              onLoaded: (composition) {
                _lottieController
                  ..duration = composition.duration
                  ..forward();

                int delayText = composition.duration.inMilliseconds - 1500;

                Future.delayed(Duration(milliseconds: delayText > 0 ? delayText : 0), () {
                  if (mounted) {
                    _startTextAnimationSequence();
                  }
                });
              },
            ),

            // Jarak vertikal yang dekat antara logo dan teks nama aplikasi
            const SizedBox(height: 12),

            // 2. Animasi Teks Nama Aplikasi (Zoom-in)
            AnimatedScale(
              scale: _showAppName ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack, // Memberikan efek memantul/zoom-in
              child: AnimatedOpacity(
                opacity: _showAppName ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: const Text(
                  'Hlaprint',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),

            // Jarak vertikal yang sangat rapat antara nama aplikasi dan versi
            const SizedBox(height: 4),

            // 3. Animasi Teks Versi Aplikasi (Zoom-in)
            AnimatedScale(
              scale: _showVersion ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutBack,
              child: AnimatedOpacity(
                opacity: _showVersion ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: Text(
                  _version,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}