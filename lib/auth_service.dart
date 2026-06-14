import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Token + sign-in handling for the XC Training Data app.
///
/// The server requires `Authorization: Bearer <jwt>` on every request. This
/// class:
///
///   - Persists the server JWT in `shared_preferences` between runs.
///   - Exchanges a Google ID token for the JWT via `POST /auth/google`.
///   - Provides a dev fallback via `POST /auth/dev-login` (server only
///     accepts this when `DEV_MODE=true`).
///   - Surfaces `authHeaders` ready to splat into an http call.
///   - Lets callers `invalidate()` a token after a `401` so the next attempt
///     re-prompts sign-in.
///
/// Token lifetime: the server currently issues 30-day JWTs. This class
/// preemptively soft-expires after 25 days so we don't burn a sync attempt
/// on a token the server is about to reject.
class AuthService {
  AuthService({
    required this.serverBase,
    required this.googleServerClientId,
  });

  /// Server base URL — no trailing path. Auth endpoints live at
  /// `$serverBase/auth/...`.
  final String serverBase;

  /// OAuth 2.0 **web** client ID from the Google Cloud Console project.
  /// Required for Google Sign-In so the issued ID token is audienced for
  /// the server. Empty string disables Google sign-in (dev-login still
  /// works against a server running with `DEV_MODE=true`).
  final String googleServerClientId;

  static const _tokenKey = 'auth_token';
  static const _emailKey = 'auth_email';
  static const _nameKey = 'auth_name';
  static const _issuedAtKey = 'auth_issued_at';

  /// Treat the token as expired this many days before the server actually
  /// rejects it, to avoid a wasted sync round-trip near the edge.
  static const _softExpiryDays = 25;

  String? _token;
  String? _email;
  String? _name;
  DateTime? _issuedAt;
  bool _initialized = false;

  String? get token => _token;
  String? get email => _email;
  String? get name => _name;
  bool get isSignedIn => _token != null;
  bool get isGoogleConfigured => googleServerClientId.isNotEmpty;

  /// `Authorization: Bearer <jwt>` ready to splat into an http call's
  /// headers map. Empty when signed out.
  Map<String, String> get authHeaders =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  /// Load a previously-persisted token. Call once on app start. Safe to
  /// call multiple times — it's a no-op after the first.
  Future<void> load() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _email = prefs.getString(_emailKey);
    _name = prefs.getString(_nameKey);
    final iso = prefs.getString(_issuedAtKey);
    _issuedAt = iso != null ? DateTime.tryParse(iso) : null;
    _initialized = true;

    if (_token != null && _issuedAt != null) {
      final age = DateTime.now().difference(_issuedAt!).inDays;
      if (age > _softExpiryDays) {
        await _clearLocal();
      }
    }

    // Initialize Google Sign-In once, if it's configured. Safe even if we
    // don't end up calling authenticate().
    if (isGoogleConfigured) {
      try {
        await GoogleSignIn.instance.initialize(
          serverClientId: googleServerClientId,
        );
      } catch (e) {
        debugPrint('[auth] GoogleSignIn.initialize failed: $e');
      }
    }
  }

  /// Sign in with Google → exchange the resulting ID token for a server
  /// JWT. Returns `null` on success, or a human-readable error string.
  Future<String?> signInWithGoogle() async {
    if (!isGoogleConfigured) {
      return 'Google Sign-In is not configured. '
          'Set GOOGLE_SERVER_CLIENT_ID via --dart-define '
          '(see CLAUDE.md "Google Sign-In setup").';
    }
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        return 'Google did not return an ID token. '
            'Check that the OAuth client is configured correctly.';
      }

      final response = await http
          .post(
            Uri.parse('$serverBase/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id_token': idToken}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return 'Server rejected token: ${response.statusCode} ${response.body}';
      }
      await _persistResponse(response.body);
      return null;
    } on GoogleSignInException catch (e) {
      // Includes user cancel, no network, etc.
      return 'Google Sign-In failed (${e.code.name}): ${e.description ?? e.code.name}';
    } catch (e) {
      return 'Sign-in error: $e';
    }
  }

  /// Dev login by email. Server must be running with `DEV_MODE=true` for
  /// `POST /auth/dev-login` to exist. Returns `null` on success, or a
  /// human-readable error string.
  Future<String?> signInWithDevEmail(String email) async {
    try {
      final response = await http
          .post(
            Uri.parse('$serverBase/auth/dev-login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return 'Dev login failed: ${response.statusCode} ${response.body}';
      }
      await _persistResponse(response.body);
      return null;
    } catch (e) {
      return 'Dev login error: $e';
    }
  }

  /// Clear local state and sign out of the Google session.
  Future<void> signOut() async {
    if (isGoogleConfigured) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (e) {
        debugPrint('[auth] GoogleSignIn.signOut failed: $e');
      }
    }
    await _clearLocal();
  }

  /// Drop the current token. Use after a `401` so the next sync prompts
  /// for fresh auth.
  Future<void> invalidate() async {
    await _clearLocal();
  }

  Future<void> _persistResponse(String body) async {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final athlete =
        (data['athlete'] as Map?)?.cast<String, dynamic>() ?? const {};
    _token = data['access_token'] as String?;
    _email = athlete['email'] as String?;
    _name = athlete['name'] as String? ?? athlete['display_name'] as String?;
    _issuedAt = DateTime.now();

    final prefs = await SharedPreferences.getInstance();
    if (_token != null) await prefs.setString(_tokenKey, _token!);
    if (_email != null) {
      await prefs.setString(_emailKey, _email!);
    } else {
      await prefs.remove(_emailKey);
    }
    if (_name != null) {
      await prefs.setString(_nameKey, _name!);
    } else {
      await prefs.remove(_nameKey);
    }
    await prefs.setString(_issuedAtKey, _issuedAt!.toIso8601String());
  }

  Future<void> _clearLocal() async {
    _token = null;
    _email = null;
    _name = null;
    _issuedAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_nameKey);
    await prefs.remove(_issuedAtKey);
  }
}
