part of '../compose_bar_test.dart';

void classificationTests() {
  testWidgets(
    'composer evidence expires during actual invitation capacity wait',
    (tester) async {
      final signer = nostr.Keys.generate();
      final key = 'a' * 64;
      final gate = RelayRateLimitGate();
      final events = <Map<String, dynamic>>[];
      var current = true;
      var reads = 0;
      await tester.pumpWidget(
        _buildComposeBar(
          uploadService: _testUploadService(signer.nsec),
          currentPubkey: signer.public,
          rateLimitGate: gate,
          relayConfig: () => _SwitchableRelayConfigNotifier(
            RelayConfig(baseUrl: 'https://relay.example', nsec: signer.nsec),
          ),
          members: [
            ChannelMember(
              pubkey: key,
              displayName: 'Alice',
              role: 'member',
              joinedAt: DateTime(2025),
            ),
          ],
          channels: [_makeCurrentChannel(), _makeSharedMemberChannel()],
          selectedReader:
              (keys, prior, viewer, channel, valid, observed) async {
                reads++;
                return {
                  key: SelectedMentionAuthorization(
                    SelectedMentionKind.ordinary,
                    false,
                    null,
                    isCurrent: () => current,
                  ),
                };
              },
          onSend: (_, _, {mediaTags = const []}) async =>
              fail('must retain exact draft'),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComposeBar)),
      );
      final session = container.read(relaySessionProvider.notifier);
      session.debugAttachSocketForTest(
        _RecordingRelaySocket(events, session.debugHandleSocketMessageForTest),
      );
      await _expandComposer(tester);
      await tester.enterText(find.byType(TextField), '@ali');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final draft = controller.text;
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      gate.activate(300);
      await tester.tap(find.text('Invite'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(reads, greaterThanOrEqualTo(3));
      expect(events.where((event) => event['kind'] == 9000), isEmpty);
      current = false;
      gate.reset();
      await tester.pumpAndSettle();
      expect(events.where((event) => event['kind'] == 9000), isEmpty);
      expect(controller.text, draft);
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );
  for (final mode in [
    'production accepted roster',
    'production multiple accepted',
    'production partial prefix',
    'production capacity',
    'production initial capacity',
    'production replacement',
    'equivalent config',
    'credential change',
    'relay change',
    'ordinary member',
    'ordinary invite',
    'fresh agent',
    'denied agent',
    'tainted unknown',
    'missing key',
    'consent change',
    'perwrite change',
    'revision change',
    'policy change',
    'accepted prefix',
    'accepted cancellation',
  ]) {
    testWidgets('fresh selected classification $mode', (tester) async {
      final signer = nostr.Keys.generate();
      final target = nostr.Keys.generate();
      final key = target.public;
      final production = mode.startsWith('production ');
      final multiple =
          mode == 'production multiple accepted' ||
          mode == 'production partial prefix';
      final second = 'b' * 64;
      final relay = nostr.Keys.generate();
      final acceptedKeys = <String>{};
      final gate = RelayRateLimitGate();
      late RelaySessionNotifier productionSession;
      NostrEvent rosterEvent() => signed(
        relay,
        39002,
        '',
        time: 100 + acceptedKeys.length,
        tags: [
          ['d', 'channel-1'],
          ['p', signer.public],
          for (final member in acceptedKeys) ['p', member, '', 'member'],
        ],
      );
      final client = _selectedRosterClient(
        relay.public,
        rosterEvent,
        extraEvents: () => [
          if (mode == 'production partial prefix' && acceptedKeys.isNotEmpty)
            signed(
              target,
              0,
              {},
              time: 200,
              tags: [
                ['auth', 'invalid-revoked-authority'],
              ],
            ),
        ],
      );
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
          rateLimitGate: production ? gate : null,
          relayHttpClient: production ? client : null,
          relayConfig: () => _SwitchableRelayConfigNotifier(
            RelayConfig(baseUrl: 'https://relay.example', nsec: signer.nsec),
          ),
          members: savedAgent
              ? []
              : [
                  ...roster,
                  if (multiple)
                    ChannelMember(
                      pubkey: second,
                      displayName: 'Bob',
                      role: 'member',
                      joinedAt: DateTime(2025),
                    ),
                ],
          relayAgents: savedAgent ? [_testAgent(key)] : [],
          channels: [_makeCurrentChannel(), _makeSharedMemberChannel()],
          selectedReader:
              (keys, prior, viewer, channel, current, observed) async {
                if (production) {
                  reads++;
                  return readSelectedMentionAuthorization(
                    productionSession,
                    keys,
                    viewer: viewer,
                    channelId: channel,
                    priorAgentKeys: prior,
                    isCurrent: current,
                    onProfileEvidence: observed,
                  );
                }
                expect(keys, {key});
                if (reads == 0) expect(prior, savedAgent ? {key} : isEmpty);
                expect(current(), isTrue);
                reads++;
                if (mode == 'revision change') {
                  observed({
                    key: NostrEvent(
                      id: '$reads',
                      pubkey: key,
                      createdAt: reads,
                      kind: 0,
                      tags: [],
                      content: '{}',
                      sig: '',
                    ),
                  });
                }
                if (mode == 'missing key') return {};
                final agent =
                    mode == 'fresh agent' ||
                    mode == 'denied agent' ||
                    mode == 'policy change' ||
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
                            respondTo:
                                (mode == 'denied agent' ||
                                    mode == 'policy change' && reads >= 2)
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
            if (production) {
              await SignedEventRelay(
                session: productionSession,
                nsec: signer.nsec,
              ).submit(
                kind: 9,
                content: '',
                tags: [
                  ['h', 'channel-1'],
                  for (final key in keys) ['p', key],
                ],
              );
            }
          },
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComposeBar)),
      );
      final session = container.read(relaySessionProvider.notifier);
      productionSession = session;
      session.debugAttachSocketForTest(
        _RecordingRelaySocket(
          events,
          session.debugHandleSocketMessageForTest,
          onEventAcknowledged: (event) {
            if (event['kind'] != 9000) return;
            accepted = true;
            if (production) {
              acceptedKeys.add(
                (event['tags'] as List).firstWhere((t) => t[0] == 'p')[1]
                    as String,
              );
              session.debugHandleSocketMessageForTest([
                'EVENT',
                'roster',
                rosterEvent().toJson(),
              ]);
            }
            if ([
              'equivalent config',
              'credential change',
              'relay change',
            ].contains(mode)) {
              container
                  .read(relayConfigProvider.notifier)
                  .update(
                    baseUrl: mode == 'relay change'
                        ? 'https://other.example'
                        : 'https://relay.example',
                    nsec: mode == 'credential change'
                        ? nostr.Keys.generate().nsec
                        : signer.nsec,
                  );
            }
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
      if (multiple) {
        await tester.enterText(find.byType(TextField), '${controller.text}@bo');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bob'));
        await tester.pumpAndSettle();
      }
      final draft = controller.text;
      if (mode == 'production initial capacity') gate.activate(300);
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (find.text('Invite').evaluate().isNotEmpty) {
        expect(events.where((event) => event['kind'] == 9000), isEmpty);
        if (mode == 'production capacity') gate.activate(300);
        if (mode == 'production replacement') {
          session.debugSupersedeConnection();
        }
        await tester.tap(find.text('Invite'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      gate.reset();
      await tester.pumpAndSettle();
      if (production) {
        final succeeds =
            mode == 'production accepted roster' ||
            mode == 'production multiple accepted';
        expect(events.where((e) => e['kind'] == 9).length, succeeds ? 1 : 0);
        expect(
          acceptedKeys.length,
          succeeds
              ? (multiple ? 2 : 1)
              : mode == 'production partial prefix'
              ? 1
              : 0,
        );
        if (succeeds) {
          expect(reads, greaterThanOrEqualTo(multiple ? 5 : 4));
        } else {
          expect(controller.text, draft);
          expect(find.byType(SnackBar), findsOneWidget);
        }
        return;
      }
      if (mode == 'revision change' || mode == 'policy change') {
        expect(reads, 2);
      }
      if (mode == 'consent change' || mode == 'perwrite change') {
        expect(reads, 3);
      }
      final succeeds = [
        'equivalent config',
        'ordinary member',
        'ordinary invite',
        'fresh agent',
      ].contains(mode);
      expect(sent, succeeds ? [key] : isNull);
      final writes = events.where((event) => event['kind'] == 9000).toList();
      expect(
        writes,
        hasLength(
          [
                    'ordinary invite',
                    'fresh agent',
                    'equivalent config',
                    'credential change',
                    'relay change',
                  ].contains(mode) ||
                  prefix
              ? 1
              : 0,
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
          ['credential change', 'relay change'].contains(mode)
              ? '' // The new identity owns a separate empty composer.
              : mode == 'accepted cancellation'
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
