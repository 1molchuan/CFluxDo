import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/widgets/community_score_tile.dart';
import 'package:m3e_ui/m3e_ui.dart';

class _CurrentUser extends CurrentUserNotifier {
  _CurrentUser(this.user);

  final User? user;

  @override
  User? build() => user;
}

Future<void> _pump(WidgetTester tester, User? user) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [currentUserProvider.overrideWith(() => _CurrentUser(user))],
      child: TranslationProvider(
        child: const MaterialApp(
          locale: Locale('zh'),
          home: Scaffold(
            body: SegmentedCardGroup(children: [CommunityScoreTile()]),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final tile = find.byKey(const ValueKey('profile-community-score'));

  testWidgets('有社区点数时显示标签、千分位数值和排行榜入口', (tester) async {
    await _pump(
      tester,
      User(id: 1, username: 'tester', trustLevel: 2, gamificationScore: 10357),
    );
    await tester.pump();

    expect(tile, findsOneWidget);
    expect(find.text('社区点数'), findsOneWidget);
    expect(find.text('10,357'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
  });

  testWidgets('游客或站点没开点数插件时不占位', (tester) async {
    await _pump(tester, null);
    await tester.pump();
    expect(tile, findsNothing);
    expect(tester.getSize(find.byType(CommunityScoreTile)), Size.zero);

    await _pump(tester, User(id: 1, username: 'tester', trustLevel: 2));
    await tester.pump();
    expect(tile, findsNothing);
    expect(find.text('社区点数'), findsNothing);
  });
}
