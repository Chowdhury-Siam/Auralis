import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data_backup.dart';
import '../storage.dart';
import 'document.dart';

class SyncController extends ChangeNotifier {
  SyncController(this.settings, this.vault, {required this.onApplied, required this.paused, this.deploymentVault}) {
    settings.captureSync = _capture;
    settings.onSaved = _schedule;
  }
  final AppSettings settings;
  final SecretVault vault;
  final SecretVault? deploymentVault;
  final VoidCallback onApplied;
  final bool Function() paused;
  HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  String? _url, _key;
  bool _closed=false, syncing=false, _again=false;
  int _generation=0, revision=0;
  DateTime? _lastStatsUpload;
  Timer? _debounce, _poll, _retry;
  WebSocket? _socket;
  int? _connectingLive;
  StreamSubscription<dynamic>? _live;
  Future<void>? _running;
  String status='Connect your devices to sync your library.';
  String? error;
  bool get connected => _url != null;
  String get url => _url ?? '';
  SyncDocument get document => SyncDocument(settings.syncState);
  static String normalize(String value) {
    final uri=Uri.tryParse(value.trim().replaceFirst(RegExp(r'/+$'),''));
    if(uri==null || uri.scheme!='https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || (uri.path.isNotEmpty && uri.path!='/') || uri.hasQuery || uri.hasFragment || (uri.hasPort && uri.port!=443)) throw const FormatException('Enter an HTTPS sync service URL without a path.');
    return uri.replace(path:'').toString();
  }
  void _changed() { if(!_closed) notifyListeners(); }
  Future<void> start() async {
    try {
      final saved=await vault.read();
      if(saved['url'] is String && saved['key'] is String) {
        _activate(normalize(saved['url'] as String),saved['key'] as String);
        unawaited(sync());
      }
    } catch (_) { error='Could not unlock sync settings. Reconnect to retry.'; _changed(); }
  }
  Future<void> connect(String endpoint,String key) async {
    endpoint=normalize(endpoint);key=key.trim();
    if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) throw const FormatException('Use the 64-character sync key from your service.');
    // Validate credentials before replacing the current connection or local state.
    await _request(endpoint,key,{'cursor':0,'ops':<String,dynamic>{}});
    await vault.write({'url':endpoint,'key':key});
    _activate(endpoint,key);
    settings.syncState['cursor']=0;
    settings.syncState['dirty']=document.records.keys.toList();
    await settings.save();
    await sync();
  }
  void _activate(String endpoint,String key) {
    _client.close(force:true);
    _client=HttpClient()..connectionTimeout=const Duration(seconds:10);
    _generation++;_socket?.close();_socket=null;unawaited(_live?.cancel());
    _debounce?.cancel();_poll?.cancel();_retry?.cancel();
    _url=endpoint;_key=key;_lastStatsUpload=null;
    final scope=sha256.convert(utf8.encode('$endpoint:$key')).toString();
    if(settings.syncState['scope']!=scope) settings.syncState={'scope':scope};
    try {
      _capture(settings.toJson());
    } catch (_) {
      // Rebuild damaged local sync metadata from the intact application data.
      settings.syncState={'scope':scope};
      _capture(settings.toJson());
    }
    _poll=Timer.periodic(const Duration(seconds:30),(_) => unawaited(sync()));
    unawaited(_connectLive(_generation));
    status='Connected. Syncing…';error=null;_changed();
  }
  void _capture(Map<String,dynamic> snapshot) {
    if(connected && !_closed) document.capture(snapshot);
  }
  void _schedule() {
    if(!connected || _closed || syncing) return;
    _debounce?.cancel();
    _debounce=Timer(const Duration(milliseconds:350),() => unawaited(sync()));
  }
  Future<Map<String,dynamic>> _request(String endpoint,String key,Map<String,dynamic> data) async {
    final request=await _client.postUrl(Uri.parse('$endpoint/v1/sync')).timeout(const Duration(seconds:15));
    request.followRedirects=false;
    request.headers.set('Authorization','Bearer $key');
    request.headers.contentType=ContentType.json;
    request.add(utf8.encode(jsonEncode(data)));
    final response=await request.close().timeout(const Duration(seconds:15));
    final bytes=<int>[];
    await for(final chunk in response.timeout(const Duration(seconds:15))) {
      if(bytes.length+chunk.length>4*1024*1024) throw const FormatException('Sync response is too large.');
      bytes.addAll(chunk);
    }
    final result=jsonDecode(utf8.decode(bytes));
    if(response.statusCode!=200 || result is! Map<String,dynamic>) throw const HttpException('Sync request failed. Check the service URL and key.');
    if(result['cursor'] is! int || (result['cursor'] as int)<0 || result['more'] is! bool || result['records'] is! Map<String,dynamic>) throw const FormatException('Invalid sync response.');
    return result;
  }
  bool _deviceStats(String key) {
    final parts=jsonDecode(key) as List;
    return (parts.first=='stats' || parts.first=='day') && parts[1]==settings.syncState['device'];
  }
  bool get _statsDue => _lastStatsUpload==null || DateTime.now().difference(_lastStatsUpload!)>=const Duration(seconds:30);
  void _schedulePending() {
    if(_closed || !connected) return;
    if(document.dirty.isNotEmpty && document.dirty.every(_deviceStats) && !_statsDue) {
      final remaining=const Duration(seconds:30)-DateTime.now().difference(_lastStatsUpload!);
      _debounce?.cancel();
      _debounce=Timer(remaining.isNegative?Duration.zero:remaining,() => unawaited(sync()));
    } else {
      _schedule();
    }
  }
  Future<void> sync() {
    if(_closed || !connected || paused()) return Future.value();
    if(_running!=null) { _again=true;return _running!; }
    final task=_sync(_generation);
    _running=task;
    return task.whenComplete(() {
      _running=null;
      if(_again) {
        _again=false;_schedule();
      } else if(!_closed && connected && error==null && document.dirty.isNotEmpty) {
        _schedulePending();
      }
    });
  }
  Future<bool> _bootstrap(int generation) async {
    await settings.save();
    final remote = <String,dynamic>{};
    var cursor = 0, more = true;
    while(more) {
      final page = await _request(_url!,_key!,{'cursor':cursor,'ops':<String,dynamic>{}});
      if(_closed || generation!=_generation || paused()) return false;
      remote.addAll(page['records'] as Map<String,dynamic>);
      cursor=page['cursor'] as int;more=page['more'] as bool;
    }
    _capture(settings.toJson());
    final merged=SyncDocument(detached(settings.syncState));
    merged.reconcileBaseline(remote);
    merged.merge(remote);
    merged.state['cursor']=cursor;
    merged.state['bootstrap']=false;
    final snapshot=merged.project(settings.toJson());
    DataBackup.validateSnapshot(snapshot);
    settings.syncState=merged.state;settings.applyJson(snapshot);
    await settings.save();revision++;onApplied();
    return true;
  }
  Future<void> _sync(int generation) async {
    syncing=true;error=null;status='Syncing your library…';_changed();
    try {
      if(document.state['bootstrap']==true && !await _bootstrap(generation)) return;
      var more=true;
      final statsAllowed=_statsDue;
      final sentKeys=<String>{};
      bool eligible(String key) => !_deviceStats(key) || statsAllowed;
      while(more && !_closed && generation==_generation && !paused()) {
        // Persist local edits/outbox before sending them, including offline changes.
        await settings.save();
        final doc=document;
        final sent=<String,dynamic>{for(final k in doc.dirty.where((k) => eligible(k) && !sentKeys.contains(k)).take(100)) k:detached(Map<String,dynamic>.from(doc.records[k] as Map))};
        sentKeys.addAll(sent.keys);
        if(sent.keys.any(_deviceStats)) _lastStatsUpload=DateTime.now();
        final result=await _request(_url!,_key!,{'cursor':doc.state['cursor'],'ops':sent});
        if(_closed || generation!=_generation || paused()) return;
        // Capture edits made while HTTP was pending before merging remote fields.
        _capture(settings.toJson());
        final merged=SyncDocument(detached(settings.syncState));
        merged.merge(result['records'] as Map<String,dynamic>);
        final remaining=merged.dirty;
        for(final e in sent.entries) {
          if(jsonEncode(merged.records[e.key])==jsonEncode(e.value)) remaining.remove(e.key);
        }
        merged.state['dirty']=remaining.toList();merged.state['cursor']=result['cursor'];
        final snapshot=merged.project(settings.toJson());
        DataBackup.validateSnapshot(snapshot);
        settings.syncState=merged.state;
        settings.applyJson(snapshot);
        await settings.save();
        revision++;onApplied();
        more=result['more'] == true || remaining.any((key) => eligible(key) && !sentKeys.contains(key));
      }
      status='Up to date across your devices.';
    } catch (_) {
      if(!_closed && generation==_generation) { _client.close(force:true);_client=HttpClient()..connectionTimeout=const Duration(seconds:10); error='Sync is pending. Check your connection, service URL and key. Local changes are kept and will retry.';status='Offline changes are saved on this device.'; }
    } finally {
      syncing=false;_changed();
    }
  }
  Future<void> _connectLive(int generation) async {
    if(_closed || generation!=_generation || !connected || _connectingLive==generation || _socket?.readyState==WebSocket.open) return;
    _connectingLive=generation;
    var abandoned=false;
    final pending=WebSocket.connect('${_url!.replaceFirst('https:','wss:')}/v1/live',headers:{'Authorization':'Bearer $_key'});
    unawaited(pending.then<void>((socket) {
      if(abandoned || _closed || generation!=_generation) unawaited(socket.close());
    },onError:(Object _) {}));
    try {
      final socket=await pending.timeout(const Duration(seconds:15));
      if(_closed || generation!=_generation) {await socket.close();return;}
      final old=_socket;_socket=socket;
      await _live?.cancel();unawaited(old?.close());
      _live=socket.listen((_) { if(syncing) { _again=true; } else { _schedule(); } },onError:(Object _) => _reconnect(generation,socket),onDone:() => _reconnect(generation,socket),cancelOnError:true);
    } catch (_) { abandoned=true;_reconnect(generation); }
    finally {if(_connectingLive==generation) _connectingLive=null;}
  }
  void _reconnect(int generation,[WebSocket? socket]) {
    if(_closed || generation!=_generation || (socket != null && !identical(socket,_socket))) return;
    _socket=null;
    _retry?.cancel();_retry=Timer(const Duration(seconds:10),() => unawaited(_connectLive(generation)));
  }
  Future<void> disconnect() async {
    // Clear the protected credentials first. A failure keeps the current account.
    await vault.write({});
    _generation++;_url=null;_key=null;
    _debounce?.cancel();_poll?.cancel();_retry?.cancel();
    await _live?.cancel();unawaited(_socket?.close());_socket=null;
    settings.syncState={};await settings.save();
    status='Disconnected. Your local library is kept.';error=null;_changed();
  }
  Future<String> connectionDetails() async {
    final generation=_generation;
    final saved=await vault.read();
    if(!connected || generation!=_generation) throw StateError('Sync is disconnected.');
    return jsonEncode({'url':saved['url'],'key':saved['key']});
  }
  void resume() { if(connected) {unawaited(sync());if(_socket==null) unawaited(_connectLive(_generation));} }
  Future<void> flush() async {
    if(_closed || !connected || paused()) return;
    final running=_running;
    if(running!=null) await running;
    _lastStatsUpload=null;
    await sync();
  }
  Future<void> close() async {
    if(_closed) return;
    try {await flush().timeout(const Duration(seconds:3));} catch (_) { /* Durable outbox retries on next launch. */ }
    _closed=true;_generation++;
    _debounce?.cancel();_poll?.cancel();_retry?.cancel();
    settings.captureSync=null;settings.onSaved=null;
    await _live?.cancel();unawaited(_socket?.close());_client.close(force:true);
    dispose();
  }
}
