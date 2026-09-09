part of '../compose_bar_test.dart';

void classificationTests() {
  for (final mode in [
    'ordinary member',
    'ordinary invite',
    'fresh agent',
    'denied agent',
    'tainted unknown',
    'missing key',
    'consent change',
    'perwrite change',
    'accepted prefix',
    'accepted cancellation',
  ]) {
    testWidgets('fresh selected classification $mode', (tester) async {
      final signer = nostr.Keys.generate();
      final key = 'a' * 64;
      final savedAgent = mode == 'tainted unknown';
      final events = <Map<String, dynamic>>[];
      final prefix = mode.startsWith('accepted');
      var reads = 0;
      var accepted = false;
      late TextEditingController controller;
      List<String>? sent;
      final roster = [
        ChannelMember(
          pubkey: key,
          displayName: 'Alice',
          role: 'member',
          joinedAt: DateTime(2025),
        ),
      ];
      await tester.pumpWidget(
        _buildComposeBar(
          uploadService: _testUploadService(signer.nsec),
          currentPubkey: signer.public,
          members: savedAgent ? [] : roster,
          relayAgents: savedAgent ? [_testAgent(key)] : [],
          channels: [_makeCurrentChannel(), _makeSharedMemberChannel()],
          selectedReader:
              (keys, prior, viewer, channel, current, observed) async {
                expect(keys, {key});
                if (reads == 0) expect(prior, savedAgent ? {key} : isEmpty);
                expect(current(), isTrue);
                reads++;
                if (mode == 'missing key') return {};
                final agent =
                    mode == 'fresh agent' ||
                    mode == 'denied agent' ||
                    (mode == 'consent change' && reads >= 2) ||
                    (mode == 'perwrite change' && reads >= 3);
                return {
                  key: SelectedMentionAuthorization(
                    savedAgent || prefix && accepted
                        ? SelectedMentionKind.unresolvedAgent
                        : agent
                        ? SelectedMentionKind.agent
                        : SelectedMentionKind.ordinary,
                    mode == 'ordinary member' || accepted,
                    agent
                        ? AgentDirectoryEntry(
                            pubkey: key,
                            ownerPubkey: viewer,
                            respondTo: mode == 'denied agent'
                                ? 'nobody'
                                : 'anyone',
                            channelIds: accepted ? [channel] : [],
                          )
                        : null,
                  ),
                };
              },
          onSend: (_, keys, {mediaTags = const []}) async {
            expect(mediaTags.where((tag) => tag.first == 'mention'), isEmpty);
            sent = keys;
          },
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComposeBar)),
      );
      final session = container.read(relaySessionProvider.notifier);
      session.debugAttachSocketForTest(
        _RecordingRelaySocket(
          events,
          session.debugHandleSocketMessageForTest,
          onEventAcknowledged: (event) {
            if (event['kind'] != 9000) return;
            accepted = true;
            if (mode == 'accepted cancellation') {
              controller.text = 'new draft';
            }
          },
        ),
      );
      await _expandComposer(tester);
      await tester.enterText(
        find.byType(TextField),
        savedAgent ? '@hel' : '@ali',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(savedAgent ? 'Helper Bot' : 'Alice'));
      await tester.pumpAndSettle();
      controller = tester.widget<TextField>(find.byType(TextField)).controller!;
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (find.text('Invite').evaluate().isNotEmpty) {
        expect(events.where((event) => event['kind'] == 9000), isEmpty);
        await tester.tap(find.text('Invite'));
        await tester.pumpAndSettle();
      }
      if (mode == 'consent change' || mode == 'perwrite change') {
        expect(reads, 3);
      }
      final succeeds = [
        'ordinary member',
        'ordinary invite',
        'fresh agent',
      ].contains(mode);
      expect(sent, succeeds ? [key] : isNull);
      final writes = events.where((event) => event['kind'] == 9000).toList();
      expect(
        writes,
        hasLength(
          ['ordinary invite', 'fresh agent'].contains(mode) || prefix ? 1 : 0,
        ),
      );
      if (writes.isNotEmpty) {
        expect(
          (writes.single['tags'] as List).where((tag) => tag[0] == 'p').single,
          ['p', key],
        );
        expect(
          writes.single['tags'],
          contains(equals(['role', mode == 'fresh agent' ? 'bot' : 'member'])),
        );
      }
      if (!succeeds) {
        expect(
          controller.text,
          mode == 'accepted cancellation'
              ? 'new draft'
              : savedAgent
              ? '@Helper Bot '
              : '@Alice ',
        );
      }
      if (prefix) {
        expect(
          find.textContaining('1 invitation(s) completed and remain'),
          findsOneWidget,
        );
      }
    });
  }
}
