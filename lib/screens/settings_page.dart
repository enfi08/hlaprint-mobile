import 'package:flutter/material.dart';
import 'package:hlaprint/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _appVersion = 'Loading...';
  String? _selectedPrinter;
  String? _selectedColorPrinter;
  List<String> _printers = [];
  String? _userRole;
  final TextEditingController _ipPrinterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUserRole();
    if (Platform.isWindows) {
      _loadPrinters(); // Only load list of printers on Windows
    } else if (Platform.isAndroid) {
      _loadIPPrinter(); // Load saved IP on Android
    }
    _loadSelectedPrinter();
    _loadSelectedColorPrinter();
    _loadVersionInfo();
  }

  @override
  void dispose() {
    _ipPrinterController.dispose();
    super.dispose();
  }

  Future<void> _loadUserRole() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userRole = prefs.getString(userRoleKey);
      });
    }
  }

  Future<void> _loadPrinters() async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', ['(Get-CimInstance Win32_Printer).Name']);
      if (result.exitCode == 0) {
        setState(() {
          final String output = result.stdout?.toString() ?? '';
          _printers = output.split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        });
      }
    }
  }

  Future<void> _loadSelectedPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedPrinter = prefs.getString(printerNameKey);
    });
  }

  Future<void> _loadSelectedColorPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _selectedColorPrinter = prefs.getString(printerColorNameKey);
      });
    }
  }

  Future<void> _loadIPPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIP = prefs.getString(ipPrinterKey) ?? '';
    if (mounted) {
      setState(() {
        _ipPrinterController.text = savedIP;
      });
    }
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = 'Version ${packageInfo.version} (${packageInfo.buildNumber})${isStaging ? " (staging)" : ""}';
      });
    }
  }

  // settings_page.dart

  Future<void> _saveSettings() async {
    debugPrint('--- _saveSettings STARTED ---');
    final prefs = await SharedPreferences.getInstance();
    bool changesMade = false;
    String savedValue = '';

    if (Platform.isAndroid) {
      if (_ipPrinterController.text.isNotEmpty) {
        final newSavedValue = _ipPrinterController.text.trim();
        final oldSavedValue = prefs.getString(ipPrinterKey) ?? ''; // Get old value for comparison

        if (oldSavedValue != newSavedValue) {
          await prefs.setString(ipPrinterKey, newSavedValue);
          changesMade = true;
          debugPrint('Android: IP changed to $newSavedValue');
        }
        savedValue = newSavedValue;
      }
    } else {
      if (_selectedPrinter != null) {
        if ((prefs.getString(printerNameKey) ?? '') != _selectedPrinter!) {
          await prefs.setString(printerNameKey, _selectedPrinter!);
          changesMade = true;
        }
        savedValue = _selectedPrinter!;
      }

      if (_userRole != 'darkstore' && _selectedColorPrinter != null) {
        String colorPrinterName = _selectedColorPrinter!;
        if ((prefs.getString(printerColorNameKey) ?? '') != colorPrinterName) {
          await prefs.setString(printerColorNameKey, colorPrinterName);
          changesMade = true;
        }

        String bwName = prefs.getString(printerNameKey) ?? savedValue;
        if (bwName.isNotEmpty) {
          savedValue = 'B/W: $bwName, Color: $colorPrinterName';
        } else {
          savedValue = 'Color Printer: $colorPrinterName';
        }
      }
      if (Platform.isWindows && savedValue.isNotEmpty && _selectedColorPrinter == null) {
        savedValue = 'Printer Default: $savedValue';
      }
    }

    debugPrint('Changes made status: $changesMade');
    debugPrint('Final saved value: $savedValue');

    String? returnMessage;

    if (savedValue.isNotEmpty) {
      if (Platform.isAndroid) {
        returnMessage = 'IP Printer has been saved successfully:\n$savedValue';
      } else if (Platform.isWindows) {
        returnMessage = 'Default Printer has been saved successfully:\n$savedValue';
      } else {
        returnMessage = 'Settings have been saved successfully.';
      }
    } else {
      returnMessage = null;
    }

    debugPrint('Return message to home page: $returnMessage');
    if (mounted) {
      Navigator.of(context).pop(returnMessage);
      debugPrint('Navigator.pop() called with message: $returnMessage');
    }
    debugPrint('--- _saveSettings FINISHED ---');
  }

  @override
  Widget build(BuildContext context) {
    final bool showColorPrinterOption = _userRole != null && _userRole != 'darkstore';
    final bool isAndroid = Platform.isAndroid;

    bool isSaveEnabled() {
      if (isAndroid) {
        return _ipPrinterController.text.isNotEmpty;
      } else {
        return _selectedPrinter != null;
      }
    }

    Widget _buildAndroidSettings() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'IP Printer Address:',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ipPrinterController,
            keyboardType: TextInputType.number, // IP addresses are numbers
            decoration: const InputDecoration(
              hintText: 'e.g., 192.168.1.100',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
              });
            },
          ),
          const SizedBox(height: 24),
        ],
      );
    }

    Widget _buildWindowsSettings() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            showColorPrinterOption ? 'B/W Printer:' : 'Select Printer:',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: _selectedPrinter,
            hint: const Text('Please select printer'),
            items: _printers.map<DropdownMenuItem<String>>((String value) {
              return DropdownMenuItem<String>(
                value: value,
                child: Text(value),
              );
            }).toList(),
            onChanged: (String? newValue) {
              setState(() {
                _selectedPrinter = newValue;
              });
            },
          ),
          if (showColorPrinterOption) ...[
            const SizedBox(height: 16),
            const Text(
              'Color Printer:',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            DropdownButton<String>(
              isExpanded: true,
              value: _selectedColorPrinter,
              hint: const Text('Please select color printer'),
              items: _printers.map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  _selectedColorPrinter = newValue;
                });
              },
            ),
          ],
          const SizedBox(height: 24),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(isAndroid ? 'Setting IP Printer' : 'Setting Default Printer'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  isAndroid ? _buildAndroidSettings() : _buildWindowsSettings(),

                  ElevatedButton(
                    onPressed: isSaveEnabled() ? _saveSettings : null,
                    child: const Text('Save'),
                  ),

                  const SizedBox(height: 20),
                  Text(
                    _appVersion,
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }
}