import 'package:dio/dio.dart';
import 'package:Hlaprint/constants.dart';
import 'package:Hlaprint/models/user_detail_model.dart';
import 'package:Hlaprint/services/auth_service.dart';

class UserService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<User> getUser() async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }

    final url = '$baseUrl/api/user';
    final headers = {
      "Authorization": "Bearer $token",
      "Accept": "application/json",
    };

    try {
      final response = await _dio.get(url, options: Options(headers: headers));

      if (response.statusCode == 200) {
        return User.fromJson(response.data);
      } else if (response.statusCode == 401) {
        throw Exception("Unauthorized. Session expired.");
      } else {
        throw Exception("Failed to load user data: ${response.statusCode}");
      }
    } on DioException catch (e, s) {
      if (e.response != null) {
        if (e.response?.statusCode == 401) {
          throw Exception("Unauthorized. Session expired.");
        }
      }
      throw Exception("Failed to connect to the server: ${e.message}");
    }
  }
}