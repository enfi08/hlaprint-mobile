import 'package:flutter/material.dart';
import 'package:Hlaprint/constants.dart';
import 'package:Hlaprint/services/versioning_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:Hlaprint/services/auto_update_manager.dart';
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
  String _rawVersion = '';
  String? _userRole;
  bool? _autoUpdateEnabled;
  final TextEditingController _ipPrinterController = TextEditingController();
  String _alternativePrintMethod = printDefault;
  final List<String> _alternativePrintOptions = [printDefault, printTypeA, printTypeB];
  bool _isCheckingUpdate = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusText = "Downloading...";
  final VersioningService _versioningService = VersioningService();

  @override
  void initState() {
    super.initState();
    _loadUserRole();
    _loadPrinters();
    _loadSelectedPrinter();
    _loadSelectedColorPrinter();
    _loadVersionInfo();
    _loadAutoUpdateSettings();
    _loadAlternativePrintSettings();
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

  Future<void> _loadAutoUpdateSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _autoUpdateEnabled = prefs.getBool('update_automatically') ?? false;
      });
    }
  }

Future<void> _loadAlternativePrintSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _alternativePrintMethod = prefs.getString(alternativePrintModeKey) ?? printDefault;
        if (!_alternativePrintOptions.contains(_alternativePrintMethod)) {
          _alternativePrintMethod = printDefault;
        }
      });
    }
  }


  Future<void> _checkForUpdate() async {
    if (!Platform.isWindows) return;

    if (_rawVersion.isEmpty) return;

    setState(() => _isCheckingUpdate = true);

    try {
      final result = await _versioningService.checkVersion(_rawVersion);

      setState(() => _isCheckingUpdate = false);

      if (result.hasUpdate) {
        _showUpdateDialog(
            result.latestVersion ?? 'Unknown',
            result.downloadUrl ?? '',
            result.message ?? 'New version available'
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message ?? 'No update available')),
          );
        }
      }
    } catch (e) {
      setState(() => _isCheckingUpdate = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error checking update: $e")),
        );
      }
    }
  }

  void _showUpdateDialog(String newVersion, String url, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Update Available ($newVersion)'),
        content: Text('$message\n\nDownload and install now? The app will restart.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _startDownload(url);
            },
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  Future<void> _startDownload(String url) async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _statusText = "Downloading...";
    });

    try {
      // 1. Download File Installer
      File installer = await _versioningService.downloadInstaller(url, (received, total) {
        if (total != -1) {
          setState(() {
            _downloadProgress = received / total;
          });
        }
      });

      // 2. Jalankan Installer
      if (await installer.exists()) {
        debugPrint("Running installer: ${installer.path}");

        setState(() {
            _statusText = "Preparing installation...";
          });
        await Future.delayed(const Duration(seconds: 1));

        debugPrint("Running Silent Installer: ${installer.path}");
        await _versioningService.runSilentInstaller(installer);
      }
    } catch (e) {
      setState(() => _isDownloading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Update failed: $e")),
        );
      }
    }
  }

  Future<void> _loadPrinters() async {
    if (!Platform.isWindows) return;

    List<String> foundPrinters = [];
    bool success = false;

    try {
      const String psCommand = 'Get-WmiObject -Class Win32_Printer | Select-Object -ExpandProperty Name';

      final result = await Process.run('powershell', ['-Command', psCommand]);

      if (result.exitCode == 0) {
        String output = result.stdout.toString().trim();
        if (output.isNotEmpty) {
          foundPrinters = output.split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();

          if (foundPrinters.isNotEmpty) {
            success = true;
          }
        }
      }
    } catch (e) {
      debugPrint("PowerShell loading failed: $e");
    }

    if (!success || foundPrinters.isEmpty) {
      try {
        debugPrint("Attempting WMIC fallback...");
        final result = await Process.run('wmic', ['printer', 'get', 'name']);

        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          final lines = output.split('\n');

          for (var line in lines) {
            var printerName = line.trim();
            // Filter header WMIC yang biasanya bernama "Name"
            if (printerName.isNotEmpty && printerName.toLowerCase() != 'name') {
              foundPrinters.add(printerName);
            }
          }
        }
      } catch (e) {
        debugPrint("WMIC loading failed: $e");
      }
    }

    if (mounted) {
      setState(() {
        _printers = foundPrinters;
        debugPrint("Printers Loaded: ${_printers.length}");
      });
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

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _rawVersion = packageInfo.version;
        _appVersion = 'Version ${packageInfo.version} ${isStaging ? "(staging)" : ""}';
      });
    }
  }

  Future<void> _saveSettings() async {
    debugPrint('--- _saveSettings STARTED ---');
    final prefs = await SharedPreferences.getInstance();
    bool changesMade = false;
    String savedValue = '';

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
    if (savedValue.isNotEmpty && _selectedColorPrinter == null) {
      savedValue = 'Printer Default: $savedValue';
    }

    debugPrint('Changes made status: $changesMade');
    debugPrint('Final saved value: $savedValue');

    String? returnMessage;

    if (savedValue.isNotEmpty) {
      returnMessage = 'Default Printer has been saved successfully:\n$savedValue';
    } else {
      returnMessage = null;
    }

    debugPrint('Return message to home page: $returnMessage');
    if (mounted) {
      Navigator.of(context).pop(returnMessage);
    }
    debugPrint('--- _saveSettings FINISHED ---');
  }

  @override
  Widget build(BuildContext context) {
    final bool showColorPrinterOption = _userRole != null && _userRole != 'darkstore';

    bool isSaveEnabled() {
      return _selectedPrinter != null;
    }

    Widget _buildDesktopSettings() {
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
        title: const Text('Setting Default Printer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPrinters,
          )
        ],
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
                  if (_autoUpdateEnabled != null) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Update Automatically"),
                      subtitle: Text(_autoUpdateEnabled! ? "Download updates in the background without interrupting." : "Check updates manually"),
                      value: _autoUpdateEnabled!,
                      onChanged: (bool value) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('update_automatically', value);
                        setState(() {
                          _autoUpdateEnabled = value;
                        });
                        if (value) {
                          AutoUpdateManager().checkAndRunAutoUpdate();
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                  ],
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Alternative ways to print"),
                      subtitle: const Text("The different ways to print in case when the default print doesn't working"),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _alternativePrintMethod,
                          items: _alternativePrintOptions.map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            );
                          }).toList(),
                          onChanged: (String? newValue) async {
                            if (newValue != null) {
                              setState(() {
                                _alternativePrintMethod = newValue;
                              });
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setString(alternativePrintModeKey, newValue);
                              debugPrint("Alternative print method saved immediately: $newValue");
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  _buildDesktopSettings(),

                    ElevatedButton(
                      onPressed: isSaveEnabled() ? _saveSettings : null,
                      child: const Text('Save'),
                    ),

                    const SizedBox(height: 20),
                    Text.rich(
                      TextSpan(
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                        children: [TextSpan(text: _appVersion)],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            if (Platform.isWindows) ...[
              const Divider(),
              const SizedBox(height: 10),
              if (_isDownloading) ...[
                LinearProgressIndicator(value: _downloadProgress),
                const SizedBox(height: 5),
                Text('$_statusText ${(_downloadProgress * 100).toStringAsFixed(0)}%'),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: _isCheckingUpdate
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.system_update),
                    label: Text(_isCheckingUpdate
                        ? 'Checking...'
                        : (_rawVersion.isEmpty ? 'Loading Version...' : 'Check for Updates')
                    ),
                    onPressed: (_isCheckingUpdate || _rawVersion.isEmpty)
                        ? null
                        : _checkForUpdate,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}