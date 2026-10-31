import 'package:easy_localization/easy_localization.dart';

import 'app_utils.dart';

abstract final class FormValidators {
  static String? email(String? value) {
    if (AppUtils.isBlank(value)) return 'auth.email_required'.tr();
    return AppUtils.isValidEmail(value!.trim())
        ? null
        : 'auth.email_invalid'.tr();
  }

  static String? name(String? value) {
    final length = value?.trim().length ?? 0;
    return length >= 2 && length <= 80 ? null : 'auth.name_length'.tr();
  }

  static String? requiredPassword(String? value) {
    return value == null || value.isEmpty ? 'auth.password_required'.tr() : null;
  }

  static String? password(String? value) {
    return value != null && value.length >= 8
        ? null
        : 'auth.password_too_short'.tr();
  }

  static String? confirmPassword(String? value, String password) {
    return value == password ? null : 'auth.passwords_do_not_match'.tr();
  }

  static String? code(String? value) {
    return RegExp(r'^\d{6,8}$').hasMatch(value?.trim() ?? '')
        ? null
        : 'auth.code_invalid'.tr();
  }

  static String? phone(String? value) {
    final phone = value?.trim() ?? '';
    if (phone.isEmpty) return null;
    return phone.length <= 32 &&
            RegExp(r'^\+?[0-9 ()-]{7,31}$').hasMatch(phone)
        ? null
        : 'profile.phone_invalid'.tr();
  }

  static String? city(String? value) {
    return (value?.trim().length ?? 0) <= 100
        ? null
        : 'profile.city_length'.tr();
  }
}
