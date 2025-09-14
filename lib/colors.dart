import 'package:flutter/material.dart';

const String buttonBlue = "#0080ff";

Color hexToColor(String hexColor) {
  final hexString = hexColor.replaceAll('#', '');
  return Color(int.parse('0xFF$hexString'));
}