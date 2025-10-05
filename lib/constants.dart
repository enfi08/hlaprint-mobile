
const bool isStaging = true;

const String baseUrl = isStaging ? "https://staging.hlaprint.com" : "https://hlaprint.com";

const String tokenKey = isStaging ? "staging_auth_token" : "auth_token";
const String userRoleKey = isStaging ? "staging_user_role" : "user_role";
const String printerNameKey = isStaging ? "staging_printer_name" : "printer_name";
const String printerColorNameKey = isStaging ? "staging_printer_color_name" : "printer_color_name";