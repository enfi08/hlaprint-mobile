import 'package:dio/dio.dart';
import 'package:Hlaprint/constants.dart';
import 'package:sentry/sentry.dart';
import 'package:Hlaprint/models/print_job_model.dart';
import 'package:Hlaprint/services/auth_service.dart';

class OrderListService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<List<PrintJob>> getOrderList({int page = 1, int limit = 8}) async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }

    final url = '$baseUrl/api/order_list?page=$page&limit=$limit';
    final headers = {
      "Authorization": "Bearer $token",
      "Accept": "application/json",
    };

    try {
      final response = await _dio.get(url, options: Options(headers: headers));

      if (response.statusCode == 200) {
        final List<dynamic> jobData = response.data['data'];
        return jobData.map((json) => PrintJob.fromJson(json)).toList();
      } else if (response.statusCode == 401) {
        throw Exception("Unauthorized. Session expired.");
      } else {
        throw Exception("Failed to load order list: ${response.statusCode}");
      }
    } on DioException catch (e, s) {
      if (e.response != null && e.response?.statusCode == 401) {
        throw Exception("Unauthorized. Session expired.");
      }
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      throw Exception("Failed to connect to the server: ${e.message}");
    }
  }
}