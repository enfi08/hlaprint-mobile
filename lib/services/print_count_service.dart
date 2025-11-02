import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:sentry/sentry.dart';

class PrintCountService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<void> updatePrintCount(int printJobId) async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }

    final url = '$baseUrl/api/print_count';
    final headers = {
      "Authorization": "Bearer $token",
      "Content-Type": "application/json",
      "Accept": "application/json",
    };

    final data = {
      "print_job_id": printJobId,
    };

    try {
      final response = await _dio.put(
        url,
        data: data,
        options: Options(headers: headers),
      );

      if (response.statusCode != 200) {
        throw Exception("Failed to update print count: ${response.statusCode}");
      }
    } on DioException catch (e, s) {
      if (e.response != null) {
        throw Exception("Server error: ${e.response?.statusCode} - ${e.response?.data}");
      }
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      throw Exception("Failed to connect to the server: ${e.message}");
    }
  }
}