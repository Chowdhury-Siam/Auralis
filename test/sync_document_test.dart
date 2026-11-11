import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralis/data_backup.dart';
import 'package:auralis/storage.dart';
import 'package:auralis/sync/document.dart';
import 'package:auralis/models.dart';
import 'package:auralis/video_playback_data.dart';

void main() {
  Map<String,dynamic> snapshot() => AppSettings(File('unused')).toJson();
  SyncDocument doc(String actor,Map<String,dynamic> snapshot) => SyncDocument({'device':actor*32})..capture(snapshot);
  test('Telegram recent history and watched marks merge across devices', () {
    const episode = VideoSource.telegram(Track(
      id: '-100123:19', title: 'Episode 19', artist: '', source: 'TV',
    ));
    final aSettings = AppSettings(File('device-a'));
    final bSettings = AppSettings(File('device-b'));
    final a = doc('a', aSettings.toJson()), b = doc('b', bSettings.toJson());
    aSettings.videoPlayback.recordVideo(episode, at: DateTime.utc(2026));
    aSettings.videoPlayback.remember(
      episode.id, const Duration(seconds: 23), const Duration(minutes: 20),
    );
    final local = VideoSource.file(Uri.file('/movies/private.mp4'), 'Local video');
    aSettings.videoPlayback.recordVideo(local);
    a.capture(aSettings.toJson());
    b.merge(a.records);
    bSettings.applyJson(b.project(bSettings.toJson()));
    expect(bSettings.videoPlayback.history.keys, [episode.id]);
    expect(bSettings.videoPlayback.history[episode.id]!.source.title, episode.title);
    expect(bSettings.videoPlayback.positions[episode.id], const Duration(seconds: 23));
    bSettings.videoPlayback.setWatched(episode, true);
    b.capture(bSettings.toJson());
    a.merge(b.records);
    aSettings.applyJson(a.project(aSettings.toJson()));
    expect(aSettings.videoPlayback.isWatched(episode), isTrue);
    expect(aSettings.videoPlayback.positions[episode.id], isNull);
    expect(aSettings.videoPlayback.history, contains(local.id));
    aSettings.videoPlayback.setWatched(episode, false);
    aSettings.videoPlayback.removeHistory(episode.id);
    a.capture(aSettings.toJson());
    b.merge(a.records);
    bSettings.applyJson(b.project(bSettings.toJson()));
    expect(bSettings.videoPlayback.isWatched(episode), isFalse);
    expect(bSettings.videoPlayback.history, isEmpty);
    DataBackup.validateSnapshot(bSettings.toJson());
  });
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
  test('restored track labels sync without adding plays or listening time', () {
    const id = 'pixelplayer:499';
    const listened = '2026-10-24T10:00:00.000Z';
    final initial = snapshot();
    initial['listening'] = {
      'tracks': {
        id: {
          'title': 'PixelPlayer track 499',
          'artist': '',
          'source': 'PixelPlayer',
          'milliseconds': 1000,
          'plays': 1,
          'lastListened': listened,
        },
      },
      'days': {
        '2026-10-24': {'milliseconds': 1000, 'plays': 1},
      },
    };
    final desktop = doc('a', initial);
    final phone = doc('b', initial);
    final phoneListening = phone.project(initial);
    phoneListening['listening']['tracks'][id]['milliseconds'] = 1600;
    phoneListening['listening']['days']['2026-10-24']['milliseconds'] = 1600;
    phone.capture(phoneListening);
    desktop.merge(phone.records);

    final corrected = desktop.project(initial);
    final track = corrected['listening']['tracks'][id] as Map;
    track['title'] = 'NIGHT';
    track['artist'] = 'Stray Kids';
    desktop.capture(corrected);
    final correctionKey = SyncDocument.key(['stats', desktop.device, id]);
    expect(desktop.dirty, contains(correctionKey));
    expect(desktop.records[correctionKey]['value']['milliseconds'], 0);
    expect(desktop.records[correctionKey]['value']['plays'], 0);

    final records = desktop.records.entries.toList();
    final ordered = doc('c', snapshot())
      ..merge(Map.fromEntries(records));
    final reversed = doc('d', snapshot())
      ..merge(Map.fromEntries(records.reversed));
    phone.merge(desktop.records);
    for (final device in [desktop, phone, ordered, reversed]) {
      final projected = device.project(initial);
      expect(projected['listening'], corrected['listening']);
      device.capture(projected);
      device.merge(desktop.records);
      expect(device.project(initial)['listening'], corrected['listening']);
      DataBackup.validateSnapshot(projected);
    }
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
