import 'dart:convert';
import 'dart:io';
import 'package:auralis/release_notes.dart';
import 'package:auralis/sync/controller.dart';
import 'package:auralis/sync/deployment.dart';
import 'package:auralis/sync/deployment_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fakes.dart';
import 'updater_test.dart' show Headers, Response;

class DeployRequest extends Fake implements HttpClientRequest {
  DeployRequest(this.method,this.uri,this.reply);
  @override
  final String method;
  @override
  final Uri uri;
  final Response Function(DeployRequest) reply;
  final bytes=<int>[];
  @override
  final headers=Headers();
  @override
  bool followRedirects=true;
  @override
  void add(List<int> data)=>bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async=>reply(this);
}
class DeployClient extends Fake implements HttpClient {
  DeployClient(this.reply);
  final Response Function(DeployRequest) reply;
  final requests=<DeployRequest>[];
  @override
  Future<HttpClientRequest> openUrl(String method,Uri url) async {
    final request=DeployRequest(method,url,reply);requests.add(request);return request;
  }
  @override
  void close({bool force=false}) {}
}
SyncDeploymentConfig config({String database='libsql://auralis-test.turso.io'})=>SyncDeploymentConfig(
  worker:'auralis-sync',account:'a'*32,cloudflareToken:'cloudflare-token',database:database,databaseToken:'database-token',key:'b'*64,
);
Response response(Map<String,dynamic> data,{int status=200})=>Response(utf8.encode(jsonEncode(data)),statusCode:status);

void main() {
  test('deployment rejects non-Turso endpoints before sending credentials',() async {
    final client=DeployClient((_)=>throw StateError('must not send'));
    final service=SyncDeployment(client:client);addTearDown(service.close);
    for(final url in [
      'http://auralis-test.turso.io', 'https://evil.example',
      'https://a.turso.io@evil.example', 'https://user@a.turso.io',
      'libsql://a.turso.io/path', 'https://a.turso.io?token=x',
      'https://a.turso.io#fragment', 'https://a.turso.io:8443',
      for(final scheme in ['https', 'libsql', 'turso']) '$scheme://a.turso.io:443',
    ]) {
      await expectLater(service.deploy(config(database:url),(_){}),throwsFormatException);
    }
    expect(client.requests,isEmpty);
  });
  test('deployment accepts Turso URL schemes and optional trailing slash',() {
    for(final scheme in ['https', 'libsql', 'turso']) {
      for(final suffix in ['', '/']) {
        expect(config(database:'$scheme://auralis-test.turso.io$suffix').databaseHttp(),
          'https://auralis-test.turso.io');
      }
    }
  });
  for(final existing in [false,true]) {
    test('deployment ${existing?'updates':'creates'} Cloudflare with bundled modules and Turso bindings',() async {
      var uploads=0;
      final client=DeployClient((r) {
        expect(r.followRedirects,isFalse);
        if(r.uri.host=='auralis-test.turso.io') {
          expect(r.headers.value('authorization'),'Bearer database-token');
          return response({'results':List.generate(5,(_)=>{'type':'ok'})});
        }
        if(r.uri.host=='api.cloudflare.com') {
          expect(r.headers.value('authorization'),'Bearer cloudflare-token');
          if(r.uri.path.endsWith('/workers/subdomain')) return response({'success':true,'result':{'subdomain':'test-account'}});
          if(r.uri.path.endsWith('/settings')) {
            return response(existing?{'success':true,'result':{'bindings':[
              {'name':'ROOM','class_name':'AuralisRoom'}, {'name':'TURSO_DATABASE_URL','text':'https://auralis-test.turso.io'},
            ]}}:{'success':false},status:existing?200:404);
          }
          if(r.method=='PUT') {
            uploads++;
            final body=utf8.decode(r.bytes);
            expect(body,contains('filename="worker.mjs"'));
            expect(body,contains('filename="turso.mjs"'));
            expect(body,contains('"name":"TURSO_AUTH_TOKEN","text":"database-token"'));
            expect(body,contains('"type":"secret_text"'));
            expect(body.contains('"migrations"'),!existing);
            return response({'success':true});
          }
          return response({'success':true});
        }
        if(r.uri.path=='/v1/info') return response({'service':'auralis-sync'});
        if(r.uri.path=='/health') return response({'service':'auralis-sync','configured':true,'backend':'turso','version':currentReleaseVersion});
        expect(uploads,1);
        return response({'cursor':0,'more':false,'records':<String,dynamic>{}});
      });
      final service=SyncDeployment(client:client);addTearDown(service.close);
      expect(await service.deploy(config(),(_){}),'https://auralis-sync.test-account.workers.dev');
      expect(uploads,1);
    });
  }
  test('deployment refuses another service before database or Worker writes',() async {
    final client=DeployClient((r)=>r.uri.path.endsWith('/workers/subdomain')
      ?response({'success':true,'result':{'subdomain':'test-account'}})
      :response({'success':true,'result':{'bindings':<dynamic>[]}}));
    final service=SyncDeployment(client:client);addTearDown(service.close);
    await expectLater(service.deploy(config(),(_){}),throwsFormatException);
    expect(client.requests.every((r)=>r.method=='GET'),isTrue);
  });
  testWidgets('setup fits phone, landscape and desktop with protected saved values', (tester) async {
    final vault=MemoryVault()..data={...config().toJson(),'version':currentReleaseVersion};
    final sync=SyncController(MemorySettings(),MemoryVault(),onApplied:(){},paused:()=>false,deploymentVault:vault);
    addTearDown(sync.close);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    for(final size in [const Size(360,480),const Size(844,390),const Size(1280,800)]) {
      tester.view.physicalSize=size;
      await tester.pumpWidget(MaterialApp(home:SyncDeploymentPage(sync:sync)));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull,reason:'$size');
      final worker=find.byKey(const ValueKey('deploy-worker'));
      await tester.scrollUntilVisible(worker,120,scrollable:find.byType(Scrollable).first);
      expect(tester.widget<TextField>(worker).controller!.text,'auralis-sync');
      for(final field in ['cloudflareToken','databaseToken','key']) {
        final finder=find.byKey(ValueKey('deploy-$field'));
        await tester.scrollUntilVisible(finder,120,scrollable:find.byType(Scrollable).first);
        expect(tester.widget<TextField>(finder).obscureText,isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}
