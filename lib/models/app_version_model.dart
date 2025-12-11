class AppVersion {
  final bool hasUpdate;
  final String? latestVersion;
  final String? downloadUrl;
  final bool forceUpdate;
  final String? message;

  AppVersion({
    required this.hasUpdate,
    this.latestVersion,
    this.downloadUrl,
    required this.forceUpdate,
    this.message,
  });

  factory AppVersion.fromJson(Map<String, dynamic> json) {
    return AppVersion(
      hasUpdate: json['has_update'] ?? false,
      latestVersion: json['latest_version'],
      downloadUrl: json['download_url'],
      forceUpdate: json['force_update'] ?? false,
      message: json['message'],
    );
  }
}