import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class ApiResponse {
  const ApiResponse({required this.statusCode, required this.bodyBytes});

  final int statusCode;
  final Uint8List bodyBytes;

  String get body => utf8.decode(bodyBytes);

  Object? decodeJson() => bodyBytes.isEmpty ? null : jsonDecode(body);
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message, {this.payload});

  final int statusCode;
  final String message;
  final Object? payload;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({
    Uri? baseUri,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : baseUri = baseUri ?? backendUriFromEnvironment(),
       _httpClient = httpClient ?? http.Client() {
    validateBackendUri(this.baseUri);
  }

  static const int maximumResponseBytes = 16 * 1024 * 1024;

  final Uri baseUri;
  final http.Client _httpClient;
  final Duration timeout;
  String? _accessToken;

  bool get isConfigured => baseUri.host.isNotEmpty;
  String? get accessToken => _accessToken;

  static Uri backendUriFromEnvironment() {
    const value = String.fromEnvironment('BACKEND_URL');
    return value.trim().isEmpty ? Uri() : Uri.parse(value.trim());
  }

  static void validateBackendUri(Uri uri) {
    if (uri.host.isEmpty) {
      return;
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'BACKEND_URL cannot contain credentials, a query, or a fragment.',
      );
    }
    final loopback =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !(loopback && uri.scheme == 'http')) {
      throw const FormatException(
        'BACKEND_URL must use HTTPS outside local development.',
      );
    }
  }

  void setAccessToken(String? token) {
    _accessToken = token;
  }

  Uri resolve(String path, [Map<String, String>? query]) {
    if (!isConfigured) {
      throw StateError('BACKEND_URL is not configured.');
    }
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$basePath$path', queryParameters: query);
  }

  Uri realtimeUri() {
    final uri = resolve('/v1/realtime');
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<ApiResponse> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) {
    return request('GET', path, query: query, authenticated: authenticated);
  }

  Future<ApiResponse> postJson(
    String path,
    Object body, {
    bool authenticated = true,
    Map<String, String>? headers,
  }) {
    return request(
      'POST',
      path,
      body: utf8.encode(jsonEncode(body)),
      authenticated: authenticated,
      headers: headers,
    );
  }

  Future<ApiResponse> putJson(
    String path,
    Object body, {
    Map<String, String>? headers,
  }) {
    return request(
      'PUT',
      path,
      body: utf8.encode(jsonEncode(body)),
      headers: headers,
    );
  }

  Future<ApiResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    bool authenticated = true,
    Map<String, String>? headers,
    Duration? requestTimeout,
  }) async {
    final effectiveTimeout = requestTimeout ?? timeout;
    final request = http.Request(method, resolve(path, query));
    request.headers.addAll({
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Request-ID': const Uuid().v4(),
      ...?headers,
    });
    if (authenticated) {
      final token = _accessToken;
      if (token == null || token.isEmpty) {
        throw StateError('An authenticated API request requires a session.');
      }
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.bodyBytes = body;
    }

    final streamed = await _httpClient.send(request).timeout(effectiveTimeout);
    final contentLength = streamed.contentLength;
    if (contentLength != null && contentLength > maximumResponseBytes) {
      throw const ApiException(413, 'API response is too large.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream.timeout(effectiveTimeout)) {
      builder.add(chunk);
      if (builder.length > maximumResponseBytes) {
        throw const ApiException(413, 'API response is too large.');
      }
    }
    final response = ApiResponse(
      statusCode: streamed.statusCode,
      bodyBytes: builder.takeBytes(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Object? payload;
      String message = 'The server rejected the request.';
      try {
        payload = response.decodeJson();
        if (payload is Map<String, dynamic> && payload['detail'] is String) {
          message = payload['detail'] as String;
        }
      } catch (_) {
        message = 'The server returned an invalid error response.';
      }
      throw ApiException(response.statusCode, message, payload: payload);
    }
    return response;
  }

  void close() {
    _httpClient.close();
  }
}
