import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hlaprint/screens/home_page.dart';
import 'package:hlaprint/services/api_service.dart';
import 'package:hlaprint/models/user_model.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:hlaprint/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  bool _isPasswordVisible = false;
  String _appVersion = '';
  List<Map<String, String>> _savedAccounts = [];
  bool _isSslEnabled = true;
  int _secretTapCount = 0;
  DateTime? _lastTapTime;

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
    _loadSavedAccounts();
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();

    bool sslStatus = prefs.getBool('ssl_enabled') ?? true;

    if (mounted) {
      setState(() {
        _isSslEnabled = sslStatus;
        _appVersion = 'Version ${packageInfo.version} ${isStaging ? "(staging)" : ""}';
      });
    }
  }

  Future<void> _loadSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedString = prefs.getString('saved_logins');
    if (savedString != null) {
      final List<dynamic> decoded = jsonDecode(savedString);
      setState(() {
        _savedAccounts = decoded.map((e) => Map<String, String>.from(e)).toList();
      });
    }
  }

  void _handleSecretTap() async {
    final now = DateTime.now();

    if (_lastTapTime == null || now.difference(_lastTapTime!) > const Duration(seconds: 1)) {
      _secretTapCount = 0;
    }

    _lastTapTime = now;
    _secretTapCount++;

    print("LOG: Tap Logo Count: $_secretTapCount");

    if (_secretTapCount == 5) {
      _secretTapCount = 0; // Reset
      await _toggleSslMode();
    }
  }

  Future<void> _toggleSslMode() async {
    final prefs = await SharedPreferences.getInstance();
    bool currentSslStatus = prefs.getBool('ssl_enabled') ?? true;

    bool newStatus = !currentSslStatus;

    await prefs.setBool('ssl_enabled', newStatus);

    String message = newStatus
        ? "SSL Enabled (SECURE MODE).\nThe apps will close. Please reopen it to apply the changes."
        : "SSL Disabled (BYPASS MODE).\nThe apps will close. Please reopen it to apply the changes.";

    debugPrint("LOG: $message");

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Row(
            children: [
              Icon(newStatus ? Icons.security : Icons.no_encryption_gmailerrorred,
                  color: newStatus ? Colors.green : Colors.red),
              SizedBox(width: 10),
              const Text("Developer Mode"),
            ],
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                exit(0);
              },
              child: const Text("OK"),
            ),
          ],
        ),
      ),
    );
  }

  void _fillCredentials(Map<String, String> account) {
    _emailController.text = account['email'] ?? '';
    _passwordController.text = account['password'] ?? '';
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
    });

    try {
      User user = await _apiService.login(
        _emailController.text,
        _passwordController.text,
      );

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => HomePage(
            currentCredentials: {
              'email': _emailController.text,
              'password': _passwordController.text,
            },
          ),
        ),
      );

    } catch (e) {
      final errorMessage = e.toString().replaceAll('Exception: ', '');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Login'),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Mendeteksi ukuran layar. Jika lebar lebih dari 600, anggap sebagai layar besar.
                bool isLargeScreen = constraints.maxWidth > 600;
                // Mengatur lebar input field dan tombol.
                double fieldWidth = isLargeScreen ? constraints.maxWidth / 2 : constraints.maxWidth;

                return SizedBox(
                  width: isLargeScreen ? fieldWidth : null,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      GestureDetector(
                        onTap: _handleSecretTap,
                        child: Image.asset(
                          'assets/icon/icon.png',
                          height: 150.0,
                        ),
                      ),
                      SizedBox(height: 16.0),
                      Text(
                        'HlaPrint',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 32.0),
                      if (_savedAccounts.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Map<String, String>>(
                              isExpanded: true,
                              hint: Row(
                                children: const [
                                  Icon(Icons.flash_on, color: Colors.orange, size: 20),
                                  SizedBox(width: 8),
                                  Text("Quick Login (Saved Accounts)"),
                                ],
                              ),
                              items: _savedAccounts.map((account) {
                                return DropdownMenuItem(
                                  value: account,
                                  child: Text(
                                    account['email'] ?? '',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w500),
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  _fillCredentials(value);
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16.0),
                      ],
                      TextField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          prefixIcon: const Icon(Icons.email_outlined),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      SizedBox(height: 16.0),
                      TextField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _isPasswordVisible
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () {
                              setState(() {
                                _isPasswordVisible = !_isPasswordVisible;
                              });
                            },
                          ),
                        ),
                        obscureText: !_isPasswordVisible,
                      ),
                      SizedBox(height: 24.0),
                      _isLoading
                          ? CircularProgressIndicator()
                          : SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _login,
                          child: Text('Login'),
                        ),
                      ),
                      const SizedBox(height: 16.0),
                      Text.rich(
                        TextSpan(
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                          children: [
                            TextSpan(text: _appVersion),
                            if (!_isSslEnabled)
                              const TextSpan(
                                text: ' (unsecured mode)',
                                style: TextStyle(
                                  color: Colors.red,
                                ),
                              ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}