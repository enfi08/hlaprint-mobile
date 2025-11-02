import 'package:shared_preferences/shared_preferences.dart';
import 'package:hlaprint/constants.dart';

class AuthService {
  Future<void> save(String token, String userRole, String shopId, bool isSkipCashier) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tokenKey, token);
    await prefs.setString(userRoleKey, userRole);
    await prefs.setString(shopIdKey, shopId);
    await prefs.setBool(skipCashierKey, isSkipCashier);
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(tokenKey);
  }

  Future<void> deleteToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokenKey);
    await prefs.remove(userRoleKey);
    await prefs.remove(shopIdKey);
  }
}