import 'package:shared_preferences/shared_preferences.dart';
import 'package:Hlaprint/constants.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  Future<void> save(String token, String userRole, String shopId, bool isSkipCashier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(tokenKey, token);
      await prefs.setString(userRoleKey, userRole);
      await prefs.setString(shopIdKey, shopId);
      await prefs.setBool(skipCashierKey, isSkipCashier);
    } catch (e) {
      debugPrint("AuthService Save Error: $e");
    }
  }

  Future<String?> getToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(tokenKey);
    } catch (e) {
      debugPrint("AuthService Read Error (Corrupted Storage): $e");
      return null;
    }
  }

  Future<void> deleteToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(tokenKey);
      await prefs.remove(userRoleKey);
      await prefs.remove(shopIdKey);
    } catch (e) {
      debugPrint("AuthService Delete Error: $e");
    }
  }
}