import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/storage_service.dart';

class BackendSettings {
  const BackendSettings.demo()
      : isDemo = true,
        url = '',
        publicKey = '';

  const BackendSettings._({
    required this.isDemo,
    required this.url,
    required this.publicKey,
  });

  final bool isDemo;
  final String url;
  final String publicKey;

  factory BackendSettings.fromEnvironment(Map<String, String> environment) {
    final mode = (environment['APP_MODE'] ?? 'demo').trim().toLowerCase();
    if (mode == 'demo') return const BackendSettings.demo();
    if (mode != 'live') {
      throw const FormatException('APP_MODE must be demo or live.');
    }

    final url = (environment['SUPABASE_URL'] ?? '').trim();
    final key = (environment['SUPABASE_ANON_KEY'] ?? '').trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        url.toLowerCase().contains('your-project')) {
      throw const FormatException('Set a real HTTPS SUPABASE_URL in .env.');
    }

    if (!_isPublicKey(key)) {
      throw const FormatException(
        'Use a Supabase publishable or anon key, never a secret/service-role key.',
      );
    }
    return BackendSettings._(isDemo: false, url: url, publicKey: key);
  }

  static bool _isPublicKey(String key) {
    if (key.startsWith('sb_publishable_')) {
      return key.length > 'sb_publishable_'.length;
    }
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(
        base64Url.normalize(parts[1]),
      )));
      return payload is Map<String, dynamic> && payload['role'] == 'anon';
    } on FormatException {
      return false;
    }
  }
}

class AppConfig {
  AppConfig._();

  static BackendSettings settings = const BackendSettings.demo();
  static SupabaseClient? supabase;

  static bool get isDemoMode => settings.isDemo;

  static Future<void> init() async {
    await dotenv.load(fileName: '.env', isOptional: true);
    settings = BackendSettings.fromEnvironment(dotenv.env);
    final storageResult = await StorageService.instance.init();
    storageResult.fold((failure) => throw failure, (_) {});

    if (settings.isDemo) return;
    await Supabase.initialize(
      url: settings.url,
      publishableKey: settings.publicKey,
    );
    supabase = Supabase.instance.client;
  }
}
