import 'dart:async';
import 'dart:io';

import 'package:auralis/channel_metadata.dart';
import 'package:auralis/channel_metadata_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const title = ChannelTitle(
  id: '12',
  provider: 'AniList',
  title: 'Official title',
  description: 'A full synopsis of the selected anime.',
  nativeTitle: '作品',
  genres: ['Action', 'Drama'],
  episodes: 12,
  minutes: 24,
  year: 2026,
  rating: 85,
);

class FakeMetadata extends ChannelMetadataRepository {
  FakeMetadata() : super(Directory('unused'));
  final requests = <int, Completer<MetadataMatch>>{};
  ChannelTitle? selected;
  @override
  Future<MetadataMatch> identify(int id, String name) =>
      requests.putIfAbsent(id, Completer<MetadataMatch>.new).future;
  @override
  Future<List<ChannelTitle>> search(
    String query, {
    MetadataKind kind = MetadataKind.any,
  }) async => [title];
  @override
  Future<void> select(int id, String name, ChannelTitle value) async {
    selected = value;
  }

  @override
  Future<MetadataMatch> identifySaved(int id) async =>
      MetadataMatch(selected: selected, manual: true);
}

void main() {
  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(320, 568), 2.0),
  ]) {
    testWidgets('channel details and manual selection fit $size / $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeMetadata();
      addTearDown(repository.close);
      var plays = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelMetadataHeader(
                channelId: -1,
                channelName: 'Channel name',
                repository: repository,
                videoCount: 8,
                onPlay: () => plays++,
              ),
            ),
          ),
        ),
      );
      repository.requests[-1]!.complete(const MetadataMatch(selected: title));
      await tester.pumpAndSettle();
      expect(find.text('Official title'), findsOneWidget);
      expect(find.text('8 channel videos'), findsOneWidget);
      final start = find.byKey(const ValueKey('channel-metadata-play'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      expect(plays, 1);
      final choose = find.byKey(const ValueKey('channel-metadata-choose'));
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(find.text('Find the correct title'), findsOneWidget);
      final candidate = find.byKey(
        const ValueKey(('metadata-candidate', 'AniList:12')),
      );
      await tester.ensureVisible(candidate);
      await tester.tap(candidate);
      await tester.pumpAndSettle();
      expect(repository.selected, title);
      expect(find.text('Find the correct title'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'late results from a previous channel never overwrite the new channel',
    (tester) async {
      final repository = FakeMetadata();
      addTearDown(repository.close);
      Future<void> show(int id) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelMetadataHeader(
                channelId: id,
                channelName: 'Channel $id',
                repository: repository,
                videoCount: 1,
              ),
            ),
          ),
        ),
      );
      await show(1);
      await show(2);
      repository.requests[1]!.complete(const MetadataMatch(selected: title));
      await tester.pumpAndSettle();
      expect(find.text('Official title'), findsNothing);
      expect(find.text('Channel 2'), findsWidgets);
      repository.requests[2]!.complete(const MetadataMatch(failed: true));
      await tester.pumpAndSettle();
      expect(find.text('Identify title'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
