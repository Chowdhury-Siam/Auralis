import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/sync/document.dart';

void main() {
  Map<String,dynamic> snapshot() => AppSettings(File('unused')).toJson();
  SyncDocument doc(String actor,Map<String,dynamic> snapshot) => SyncDocument({'device':actor*32})..capture(snapshot);
  test('concurrent edits, deletions and duplicate playlist names converge without losing unrelated entries',() {
    final initial=snapshot();initial['favoriteIds']=['old'];initial['playlists']={'Mix':['old']};
    final a=doc('a',initial),b=doc('b',initial);
    final left=detached(initial),right=detached(initial);
    left['favoriteIds']=['a'];right['favoriteIds']=['old','b'];
    left['playlists']={'Mix':['old','a']};right['playlists']={'mix':['old','b']};
    a.capture(left);b.capture(right);a.merge(b.records);b.merge(a.records);
    final result=a.project(left),other=b.project(right);
    expect(result,other);
    expect(result['favoriteIds'],['a','b']);
    expect((result['playlists'] as Map).length,1);
    // Case-only rename is a new header; separate entries within the live name remain deterministic.
    DataBackup.validateSnapshot(result);
    final before=jsonEncode(result);
    a.capture(result);a.merge(b.records);expect(jsonEncode(a.project(result)),before);
  });
  test('independent additions to one playlist merge and deleting the playlist prevents resurrection',() {
    final initial=snapshot();initial['playlists']={'Mix':['old']};
    final a=doc('a',initial),b=doc('b',initial);
    final left=detached(initial),right=detached(initial);
    left['playlists']={'Mix':['old','a']};right['playlists']={'Mix':['old','b']};
    a.capture(left);b.capture(right);a.merge(b.records);
    var result=a.project(left);
    expect((result['playlists'] as Map)['Mix'],containsAll(['old','a','b']));
    result['playlists']={};a.capture(result);a.merge(b.records);
    expect(a.project(result)['playlists'],isEmpty);
  });
  test('copied initial listening history is counted once; new device time adds exactly once',() {
    final initial=snapshot();initial['listening']={'tracks':{'song':{'title':'Song','artist':'Artist','source':'Channel','milliseconds':1000,'plays':1,'lastListened':null}},'days':{'2026-10-24':{'milliseconds':1000,'plays':1}}};
    final a=doc('a',initial),b=doc('b',initial);
    a.merge(b.records);b.merge(a.records);
    var left=a.project(initial),right=b.project(initial);
    expect((left['listening'] as Map)['tracks']['song']['milliseconds'],1000);
    left=detached(left);right=detached(right);
    left['listening']['tracks']['song']['milliseconds']=1500;
    left['listening']['days']['2026-10-24']['milliseconds']=1500;
    right['listening']['tracks']['song']['milliseconds']=1700;
    right['listening']['days']['2026-10-24']['milliseconds']=1700;
    a.capture(left);b.capture(right);a.merge(b.records);b.merge(a.records);
    final result=a.project(left);
    expect(result['listening']['tracks']['song']['milliseconds'],2200);
    expect(result['listening']['days']['2026-10-24']['milliseconds'],2200);
    expect(result['listening']['tracks']['song']['plays'],1);
    a.capture(result);a.merge(b.records);
    expect(a.project(result)['listening'],result['listening']);
  });
  test('pairing a restored aggregate does not re-count existing cloud device components',() {
    final initial=snapshot();initial['listening']={'tracks':{'song':{'title':'Song','artist':'Artist','source':'Channel','milliseconds':1000,'plays':1,'lastListened':null}},'days':{'2026-10-24':{'milliseconds':1000,'plays':1}}};
    final old=doc('a',initial);
    final local=detached(initial);
    local['listening']['tracks']['song']['milliseconds']=1500;
    local['listening']['days']['2026-10-24']['milliseconds']=1500;
    old.capture(local);
    final aggregate=old.project(local);
    final paired=doc('b',aggregate);
    paired.reconcileBaseline(old.records);paired.merge(old.records);
    final result=paired.project(aggregate);
    expect(result['listening']['tracks']['song']['milliseconds'],1500);
    expect(result['listening']['days']['2026-10-24']['milliseconds'],1500);
    expect(result['listening']['tracks']['song']['plays'],1);
  });
  test('sync metadata and local update notices survive restart but never enter portable backups',() async {
    final dir=await Directory.systemTemp.createTemp('auralis-sync-state');addTearDown(()=>dir.delete(recursive:true));
    final settings=AppSettings(File('${dir.path}/settings.json'));
    settings.syncState={'device':'a'*32};
    settings.captureSync=(data)=>SyncDocument(settings.syncState).capture(data);
    settings.lastSeenRelease='0.1.64';settings.favoriteIds.add('song');await settings.save();
    final loaded=AppSettings(settings.file);await loaded.load();
    expect(loaded.syncState['dirty'],isNotEmpty);expect(loaded.lastSeenRelease,'0.1.64');
    final backup=DataBackup.create(settings,DateTime.now());
    expect(backup.snapshot.containsKey('_sync'),isFalse);expect(backup.snapshot.containsKey('_lastSeenRelease'),isFalse);
    DataBackup.parse(backup.encode());
    final localVolume=settings.volume;
    final projected=SyncDocument(loaded.syncState).project(settings.toJson());
    expect(projected['volume'],localVolume);
    expect(projected['automaticUpdates'],settings.automaticUpdates);
  });
}
