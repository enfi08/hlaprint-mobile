import 'package:flutter/material.dart';
import 'package:hlaprint/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:hlaprint/services/versioning_service.dart';
import 'package:hlaprint/services/auto_update_manager.dart';
import 'package:open_file_plus/open_file_plus.dart';
import 'dart:io';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _appVersion = 'Loading...';
  String _rawVersion = '';
  String? _selectedPrinter;
  String? _selectedColorPrinter;
  List<String> _printers = [];
  String? _userRole;
  bool _isSslEnabled = true;
  bool? _autoUpdateEnabled;
  final TextEditingController _ipPrinterController = TextEditingController();

  bool _isCheckingUpdate = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  final VersioningService _versioningService = VersioningService();

  @override
  void initState() {
    super.initState();
    _loadUserRole();
    if (Platform.isWindows || Platform.isMacOS) {
      _loadPrinters(); // Only load list of printers on Windows
    } else if (Platform.isAndroid) {
      _loadIPPrinter(); // Load saved IP on Android
    }
    _loadSelectedPrinter();
    _loadSelectedColorPrinter();
    _loadVersionInfo();
    _loadAutoUpdateSettings();
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

  Future<void> _loadPrinters() async {
    if (Platform.isWindows) {
      // ... (Kode Windows Anda yang sudah jalan biarkan saja)
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
    } else if (Platform.isMacOS) {
      // --- DEBUGGING START ---
      debugPrint("--- [MacOS] Starting _loadPrinters ---");
      try {
        // Menjalankan perintah lpstat -p untuk melihat status printer
        final result = await Process.run('lpstat', ['-p']);

        // Log hasil raw output untuk diagnosa
        debugPrint("[MacOS] lpstat exitCode: ${result.exitCode}");
        debugPrint("[MacOS] lpstat stdout:\n${result.stdout}");
        if (result.stderr.toString().isNotEmpty) {
          debugPrint("[MacOS] lpstat stderr:\n${result.stderr}");
        }

        if (result.exitCode == 0) {
          final String output = result.stdout?.toString() ?? '';
          final List<String> loadedPrinters = [];

          final lines = output.split('\n');
          for (var line in lines) {
            line = line.trim();
            if (line.isEmpty) continue;

            // PERBAIKAN: Gunakan RegExp(r'\s+') untuk handle spasi ganda
            // Contoh output: "printer Epson_L360 is idle..."
            final parts = line.split(RegExp(r'\s+'));

            // Log setiap baris yang diproses
            // debugPrint("[MacOS] Processing line parts: $parts");

            if (parts.length > 1 && parts[0] == 'printer') {
              // parts[1] adalah nama queue printer (cth: Brother_DCP_T720DW)
              final printerName = parts[1];
              loadedPrinters.add(printerName);
              debugPrint("[MacOS] Found printer: $printerName");
            }
          }

          if (loadedPrinters.isEmpty) {
            debugPrint("[MacOS] Warning: No printers parsing found even though command success.");
          }

          setState(() {
            _printers = loadedPrinters;
          });

          debugPrint("[MacOS] Final Printer List: $_printers");
        } else {
          debugPrint("[MacOS] Failed to load printers. Exit code is not 0.");
        }
      } catch (e, stackTrace) {
        debugPrint("[MacOS] Error executing lpstat: $e");
        debugPrint("[MacOS] StackTrace: $stackTrace");
      }
      debugPrint("--- [MacOS] Finished _loadPrinters ---");
      // --- DEBUGGING END ---
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
    final prefs = await SharedPreferences.getInstance();
    final bool sslStatus = prefs.getBool('ssl_enabled') ?? true;
    if (mounted) {
      setState(() {
        _isSslEnabled = sslStatus;
        _rawVersion = packageInfo.version;
        _appVersion = 'Version ${packageInfo.version} ${isStaging ? "(staging)" : ""}';
      });
    }
  }

  Future<void> _checkForUpdate() async {
    setState(() => _isCheckingUpdate = true);

    debugPrint("🔍 DEBUG: Starting checkVersion...");

    try {
      final result = await _versioningService.checkVersion(_rawVersion);
      setState(() => _isCheckingUpdate = false);

      debugPrint("🔍 DEBUG: Update info received. HasUpdate: ${result.hasUpdate}, URL: ${result.downloadUrl}");

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
        content: Text('$message\n\nDo you want to download and install now? The application will close automatically.'),
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
    });

    debugPrint("🔍 DEBUG: Starting download from ${url}");

    try {
      // 1. Download File
      File installer = await _versioningService.downloadInstaller(url, (received, total) {
        if (total != -1) {
          setState(() {
            _downloadProgress = received / total;
          });
        }
      });

      debugPrint("🔍 DEBUG: Download finished. File path: ${installer.path}");
      debugPrint("🔍 DEBUG: File exists check: ${await installer.exists()}");
      // 2. Jalankan Installer
      if (await installer.exists()) {
        debugPrint("Running installer: ${installer.path}");

        if (Platform.isWindows) {
          await Process.start(
            installer.path,
            [],
            mode: ProcessStartMode.detached,
          );
          exit(0);
        } else if (Platform.isAndroid) {
          final result = await OpenFile.open(
            installer.path,
            type: "application/vnd.android.package-archive",
          );
          if (result.type != ResultType.done) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Install error: ${result.message}")),
              );
            }
          }
        } else if (Platform.isMacOS) {
          debugPrint("🔍 DEBUG: Opening MacOS DMG...");

          final result = await OpenFile.open(installer.path);

          debugPrint("🔍 DEBUG: OpenFile Result: ${result.type}");

          if (result.type != ResultType.done && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Open Failed: ${result.message}"))
            );
          }
        }
      }
    } catch (e) {
      setState(() => _isDownloading = false);
      debugPrint("🔍 DEBUG: Download failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Update failed: $e")),
        );
      }
    }
  }

  Future<void> _saveSettings() async {
    debugPrint('--- _saveSettings STARTED ---');
    final prefs = await SharedPreferences.getInstance();
    bool changesMade = false;
    String savedValue = '';

    if (Platform.isAndroid || Platform.isIOS) {
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
      if (savedValue.isNotEmpty && _selectedColorPrinter == null) {
        savedValue = 'Printer Default: $savedValue';
      }
    }

    debugPrint('Changes made status: $changesMade');
    debugPrint('Final saved value: $savedValue');

    String? returnMessage;

    if (savedValue.isNotEmpty) {
      if (Platform.isAndroid || Platform.isIOS) {
        returnMessage = 'IP Printer has been saved successfully:\n$savedValue';
      } else {
        returnMessage = 'Default Printer has been saved successfully:\n$savedValue';
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
        title: Text(isAndroid ? 'Setting IP Printer' : 'Setting Default Printer'),
      ),
      body: SafeArea(
        child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (Platform.isWindows && _autoUpdateEnabled != null) ...[
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
                  isAndroid ? _buildAndroidSettings() : _buildDesktopSettings(),

                  ElevatedButton(
                    onPressed: isSaveEnabled() ? _saveSettings : null,
                    child: const Text('Save'),
                  ),

                  const SizedBox(height: 20),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
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
            ),
            if (Platform.isWindows || Platform.isAndroid || Platform.isMacOS) ...[
              const Divider(),
              const SizedBox(height: 10),
              // Label "Application Update:" dihapus sesuai request
              if (_isDownloading) ...[
                LinearProgressIndicator(value: _downloadProgress),
                const SizedBox(height: 5),
                Text('Downloading... ${(_downloadProgress * 100).toStringAsFixed(0)}%'),
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
      ),
    );
  }
}