import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A whole reply: status, headers (names in lower case) and body.
class Reply {
  Reply(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  String? header(String name) => headers[name.toLowerCase()];
  String get text => utf8.decode(body);
}

/// A reply whose body is still arriving (the answer to a question, written as it comes).
class Streamed {
  Streamed(this._client, this.status, this.headers, this.body);
  final http.Client _client;
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  void close() => _client.close();
}

/// HTTP for the phone and the browser alike (package:http: dart:io on the phone, fetch in the web app
/// the PC agent serves), so one set of requests works in both.
class Net {
  /// Sends a request; [timeout] is how long the reply may take to start, and the longest gap between two
  /// parts of its body.
  static Future<Streamed> open(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = http.Client();
    try {
      final req = http.Request(method, url)..headers.addAll(headers);
      // a sized body, not chunked
      if (body != null) req.bodyBytes = body;
      final res = await client.send(req).timeout(timeout);
      return Streamed(
        client,
        res.statusCode,
        res.headers,
        res.stream.timeout(timeout),
      );
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  /// The same, with the whole body; more than [limit] bytes is refused, so something posing as the agent
  /// can't fill the phone's memory.
  static Future<Reply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = const Duration(seconds: 10),
    int? limit,
  }) async {
    final s = await open(
      method,
      url,
      headers: headers,
      body: body,
      timeout: timeout,
    );
    try {
      final b = BytesBuilder(copy: false);
      await for (final chunk in s.body) {
        b.add(chunk);
        if (limit != null && b.length > limit) {
          throw const FormatException('reply too large');
        }
      }
      return Reply(s.status, s.headers, b.takeBytes());
    } finally {
      s.close();
    }
  }
}
