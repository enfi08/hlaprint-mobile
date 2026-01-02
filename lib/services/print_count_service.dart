import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:sentry/sentry.dart';

class PrintCountService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

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

    int retryCount = 0;
    const int maxRetries = 3;

    while (true) {
      try {
        final response = await _dio.put(
          url,
          data: data,
          options: Options(headers: headers),
        );

        if (response.statusCode != 200) {
          throw Exception(
              "Failed to update print count: ${response.statusCode}");
        }
        return;
      } on DioException catch (e, s) {
        final bool isConnectionError = _isConnectionClosedError(e);

        if (isConnectionError && retryCount < maxRetries) {
          retryCount++;
          await Future.delayed(Duration(milliseconds: 500 * retryCount));
          continue;
        }
        if (e.response != null) {
          throw Exception(
              "Server error: ${e.response?.statusCode} - ${e.response?.data}");
        }
        await Sentry.captureException(
          e,
          stackTrace: s,
        );
        throw Exception("Failed to connect to the server: ${e.message}");
      } catch (e, s) {
        await Sentry.captureException(e, stackTrace: s);
        rethrow;
      }
    }
  }

  bool _isConnectionClosedError(DioException e) {
    final msg = e.message ?? '';
    final errorStr = e.error?.toString() ?? '';

    return msg.contains('Connection closed') ||
        errorStr.contains('Connection closed') ||
        errorStr.contains('HttpException') ||
        e.type == DioExceptionType.connectionError ||
        (e.type == DioExceptionType.unknown && errorStr.contains('SocketException'));
  }
}