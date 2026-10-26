import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const currentSyncWorkerVersion = '0.1.76';

class SyncDeploymentConfig {
  SyncDeploymentConfig({
    required String worker,
    required String account,
    required String cloudflareToken,
    required String database,
    required String databaseToken,
    required String key,
    this.automatic = true,
  }) : worker = worker.trim().toLowerCase(),
       account = account.trim(),
       cloudflareToken = cloudflareToken.trim(),
       database = database.trim(),
       databaseToken = databaseToken.trim(),
       key = key.trim();
  final bool automatic;
  factory SyncDeploymentConfig.fromJson(Map<String, dynamic> p) =>
      SyncDeploymentConfig(
        worker: p['worker'] as String? ?? '',
        account: p['account'] as String? ?? '',
        cloudflareToken: p['cloudflareToken'] as String? ?? '',
        database: p['database'] as String? ?? '',
        databaseToken: p['databaseToken'] as String? ?? '',
        key: p['key'] as String? ?? '',
        automatic: p['automatic'] != false,
      );
  final String worker, account, cloudflareToken, database, databaseToken, key;
  String databaseHttp() {
    final normalized = database.replaceFirst(
      RegExp(r'^(libsql|turso)://'),
      'https://',
    );
    // Check the entered form before Uri normalizes away explicit HTTPS port 443.
    if (!RegExp(r'^https://[a-z0-9-]+\.turso\.io/?$').hasMatch(normalized)) {
      throw const FormatException(
        'Enter your Turso database URL, such as libsql://auralis-yourname.turso.io.',
      );
    }
    return Uri.parse(normalized).origin;
  }

  void validate() {
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(worker)) {
      throw const FormatException(
        'Use 1–63 lowercase letters, numbers or dashes for the Worker name.',
      );
    }
    if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(account)) {
      throw const FormatException(
        'Enter your 32-character Cloudflare Account ID.',
      );
    }
    if (cloudflareToken.isEmpty ||
        databaseToken.isEmpty ||
        [cloudflareToken, databaseToken].any((v) => v.contains(RegExp(r'\s')))) {
      throw const FormatException(
        'Enter your Cloudflare API token and Turso database token.',
      );
    }
    databaseHttp();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Use a 64-character private sync key.');
    }
  }

  Map<String, dynamic> toJson() => {
    'worker': worker,
    'account': account,
    'cloudflareToken': cloudflareToken,
    'database': database,
    'databaseToken': databaseToken,
    'key': key,
    'automatic': automatic,
  };
}

class SyncDeployment {
  SyncDeployment({
    HttpClient? client,
    Future<String> Function(String)? loadAsset,
  }) : _client =
           client ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _asset = loadAsset ?? rootBundle.loadString;
  final HttpClient _client;
  final Future<String> Function(String) _asset;
  void close() => _client.close(force: true);
  Future<(int, Map<String, dynamic>)> _request(
    String method,
    Uri url, {
    String? token,
    List<int>? bytes,
    String contentType = 'application/json',
  }) async {
    final request = await _client
        .openUrl(method, url)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    if (bytes != null) {
      request.headers.set('Content-Type', contentType);
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final output = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (output.length + chunk.length > 4 * 1024 * 1024) {
        throw const FormatException('Deployment response is too large.');
      }
      output.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(output));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid deployment response.');
    }
    return (response.statusCode, decoded);
  }

  Future<Map<String, dynamic>> _cf(
    SyncDeploymentConfig c,
    String method,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final (status, body) = await _request(
      method,
      Uri.parse(
        'https://api.cloudflare.com/client/v4/accounts/${c.account}/$path',
      ),
      token: c.cloudflareToken,
      bytes: data == null ? null : utf8.encode(jsonEncode(data)),
    );
    if (status < 200 || status >= 300 || body['success'] != true) {
      throw FormatException(
        'Cloudflare request failed (HTTP $status). Check account permissions and retry.',
      );
    }
    return body;
  }

  Future<void> _verify(String url, String key, {bool turso = false}) async {
    final (status, health) = await _request('GET', Uri.parse('$url/health'));
    if (status != 200 ||
        health['service'] != 'auralis-sync' ||
        health['configured'] != true ||
        (turso &&
            (health['backend'] != 'turso' ||
                health['version'] != currentSyncWorkerVersion))) {
      throw const FormatException('The Auralis sync service is not ready.');
    }
    if (health['accounts'] == true) {
      final (code, info) = await _request(
        'GET',
        Uri.parse('$url/v1/info'),
        token: key,
      );
      if (code != 200 || info['service'] != 'auralis-sync') {
        throw const FormatException('Could not verify Worker ownership.');
      }
      return;
    }
    final (syncStatus, data) = await _request(
      'POST',
      Uri.parse('$url/v1/sync'),
      token: key,
      bytes: utf8.encode('{"cursor":0,"ops":{}}'),
    );
    if (syncStatus != 200 || data['records'] is! Map || data['cursor'] is! int) {
      throw const FormatException(
        'Could not verify the sync key and database.',
      );
    }
  }

  Future<String> deploy(
    SyncDeploymentConfig c,
    void Function(String) progress,
  ) async {
    c.validate();
    progress('Checking Cloudflare…');
    final account = await _cf(c, 'GET', 'workers/subdomain');
    final subdomain = (account['result'] as Map?)?['subdomain'];
    if (subdomain is! String || !RegExp(r'^[a-z0-9-]+$').hasMatch(subdomain)) {
      throw const FormatException(
        'Create your workers.dev subdomain in Cloudflare Workers & Pages first.',
      );
    }
    final url = 'https://${c.worker}.$subdomain.workers.dev',
        path = 'workers/scripts/${c.worker}';
    final (status, settings) = await _request(
      'GET',
      Uri.parse(
        'https://api.cloudflare.com/client/v4/accounts/${c.account}/$path/settings',
      ),
      token: c.cloudflareToken,
    );
    final existing = status != 404;
    if (existing) {
      if (status != 200 || settings['success'] != true) {
        throw const FormatException(
          'Could not inspect the existing Worker. Check Cloudflare permissions.',
        );
      }
      final bindings = (settings['result'] as Map?)?['bindings'];
      if (bindings is! List ||
          !bindings.any(
            (b) =>
                b is Map &&
                b['name'] == 'ROOM' &&
                b['class_name'] == 'AuralisRoom',
          )) {
        throw const FormatException(
          'That Worker name belongs to another service. Choose a new name.',
        );
      }
      final database = bindings
          .whereType<Map>()
          .where((b) => b['name'] == 'TURSO_DATABASE_URL')
          .toList();
      if (database.length != 1 || database.single['text'] != c.databaseHttp()) {
        throw const FormatException(
          'Use a new Worker name for a different database or an older sync service. Existing cloud data is kept.',
        );
      }
      final (authStatus, identity) = await _request(
        'GET',
        Uri.parse('$url/v1/info'),
        token: c.key,
      );
      if (authStatus != 200 || identity['service'] != 'auralis-sync') {
        throw const FormatException(
          'Use this service’s existing private sync key when redeploying.',
        );
      }
    }
    progress('Preparing Turso database…');
    final schema = await _asset('cloud/worker/schema.sql');
    final statements = schema
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final (dbStatus, db) = await _request(
      'POST',
      Uri.parse('${c.databaseHttp()}/v2/pipeline'),
      token: c.databaseToken,
      bytes: utf8.encode(
        jsonEncode({
          'requests': [
            for (final sql in statements)
              {
                'type': 'execute',
                'stmt': {'sql': sql},
              },
            {'type': 'close'},
          ],
        }),
      ),
    );
    final results = db['results'];
    if (dbStatus != 200 ||
        results is! List ||
        results.length != statements.length + 1 ||
        results.any((r) => r is! Map || r['type'] != 'ok')) {
      throw const FormatException(
        'Could not prepare Turso. Check the database URL and write token.',
      );
    }
    progress('Deploying Auralis Worker…');
    final metadata = <String, dynamic>{
      'main_module': 'worker.mjs',
      'compatibility_date': '2026-10-01',
      if (!existing)
        'migrations': {
          'new_tag': 'v1',
          'new_sqlite_classes': ['AuralisRoom'],
        },
      'bindings': [
        {
          'type': 'durable_object_namespace',
          'name': 'ROOM',
          'class_name': 'AuralisRoom',
        },
        {
          'type': 'plain_text',
          'name': 'AURALIS_VERSION',
          'text': currentSyncWorkerVersion,
        },
        {
          'type': 'plain_text',
          'name': 'TURSO_DATABASE_URL',
          'text': c.databaseHttp(),
        },
        {
          'type': 'secret_text',
          'name': 'TURSO_AUTH_TOKEN',
          'text': c.databaseToken,
        },
        {'type': 'secret_text', 'name': 'AURALIS_SYNC_KEY', 'text': c.key},
        {'type': 'secret_text', 'name': 'JWT_SECRET', 'text': c.key},
      ],
    };
    final boundary = 'auralis-${DateTime.now().microsecondsSinceEpoch}';
    final body = StringBuffer();
    void part(String name, String type, String value, {bool file = false}) {
      body.write(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"${file ? '; filename="$name"' : ''}\r\nContent-Type: $type\r\n\r\n$value\r\n',
      );
    }

    part('metadata', 'application/json', jsonEncode(metadata));
    for (final name in ['worker.mjs', 'turso.mjs', 'accounts.mjs']) {
      part(
        name,
        'application/javascript+module',
        await _asset('cloud/worker/$name'),
        file: true,
      );
    }
    body.write('--$boundary--\r\n');
    final (uploadStatus, uploaded) = await _request(
      'PUT',
      Uri.parse(
        'https://api.cloudflare.com/client/v4/accounts/${c.account}/$path',
      ),
      token: c.cloudflareToken,
      contentType: 'multipart/form-data; boundary=$boundary',
      bytes: utf8.encode(body.toString()),
    );
    if (uploadStatus < 200 ||
        uploadStatus >= 300 ||
        uploaded['success'] != true) {
      throw FormatException(
        'Worker upload failed (HTTP $uploadStatus). Check Workers Scripts Edit permissions and retry.',
      );
    }
    await _cf(
      c,
      'POST',
      '$path/subdomain',
      data: {'enabled': true, 'previews_enabled': false},
    );
    progress('Checking deployed service…');
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await _verify(url, c.key, turso: true);
        final (_, health) = await _request('GET', Uri.parse('$url/health'));
        if (health['accounts'] == true) {
          final (saved, _) = await _request(
            'PUT',
            Uri.parse('$url/v1/bootstrap/deployment'),
            token: c.key,
            bytes: utf8.encode(jsonEncode(c.toJson())),
          );
          if (saved != 200) {
            throw const FormatException(
              'Could not save owner recovery credentials. Retry with the same JWT secret.',
            );
          }
        }
        return url;
      } catch (_) {
        if (attempt == 5) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw const FormatException(
      'Deployment health check failed. Retry deployment.',
    );
  }
}
