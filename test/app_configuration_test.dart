import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/config/app_config.dart';
import 'package:salahly/src/utils/app_utils.dart';

String _testJwt(String role) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({'role': role})));
  return 'test-header.$payload.test-signature';
}

Map<String, String> _live(String key) => {
      'APP_MODE': 'live',
      'SUPABASE_URL': 'https://test-project.supabase.co',
      'SUPABASE_ANON_KEY': key,
    };

Map<String, String> _flatten(Map<String, dynamic> source, [String prefix = '']) {
  final strings = <String, String>{};
  for (final entry in source.entries) {
    final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is Map<String, dynamic>) {
      strings.addAll(_flatten(value, key));
    } else {
      strings[key] = value as String;
    }
  }
  return strings;
}

void main() {
  group('Backend settings', () {
    test('defaults safely to demo and never needs a client', () {
      expect(BackendSettings.fromEnvironment({}).isDemo, isTrue);
      final settings = BackendSettings.fromEnvironment({
        'APP_MODE': 'demo',
        'SUPABASE_URL': 'dummy',
        'SUPABASE_ANON_KEY': 'dummy',
      });
      expect(settings.isDemo, isTrue);
      expect(settings.url, isEmpty);
      expect(settings.publicKey, isEmpty);
    });

    test('accepts public publishable and legacy anon key formats', () {
      expect(BackendSettings.fromEnvironment(_live('sb_publishable_test_fixture')).isDemo, isFalse);
      expect(BackendSettings.fromEnvironment(_live(_testJwt('anon'))).isDemo, isFalse);
    });

    test('rejects secret, service-role, malformed, and dummy live keys', () {
      for (final key in ['sb_secret_test_fixture', _testJwt('service_role'), 'bad.jwt.key', 'your-public-anon-key', '']) {
        expect(() => BackendSettings.fromEnvironment(_live(key)), throwsFormatException);
      }
    });

    test('invalid mode, placeholder URL, and insecure URL fail explicitly', () {
      expect(() => BackendSettings.fromEnvironment({'APP_MODE': 'production'}), throwsFormatException);
      for (final url in ['https://your-project.supabase.co', 'http://test.supabase.co', 'not a url']) {
        final environment = _live('sb_publishable_test_fixture')..['SUPABASE_URL'] = url;
        expect(() => BackendSettings.fromEnvironment(environment), throwsFormatException);
      }
    });
  });

  test('email validation checks the entire input and supports subdomains', () {
    expect(AppUtils.isValidEmail('user@accounts.example.com'), isTrue);
    expect(AppUtils.isValidEmail('user@example.com unexpected'), isFalse);
    expect(AppUtils.isValidEmail('user@@example.com'), isFalse);
    expect(AppUtils.isValidEmail('user@example'), isFalse);
  });

  test('English and Arabic have identical keys and interpolation fields', () {
    final english = _flatten(jsonDecode(File('assets/translations/en.json').readAsStringSync()) as Map<String, dynamic>);
    final arabic = _flatten(jsonDecode(File('assets/translations/ar.json').readAsStringSync()) as Map<String, dynamic>);
    expect(arabic.keys.toSet(), english.keys.toSet());
    final placeholder = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
    for (final key in english.keys) {
      expect(arabic[key], isNotEmpty, reason: key);
      expect(
        placeholder.allMatches(arabic[key]!).map((match) => match.group(1)).toSet(),
        placeholder.allMatches(english[key]!).map((match) => match.group(1)).toSet(),
        reason: key,
      );
    }
    expect(RegExp(r'[\u0600-\u06ff]').hasMatch(arabic['auth.sign_in']!), isTrue);
  });
}
