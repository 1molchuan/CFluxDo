import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/sidebar_section.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/pinned_categories_provider.dart';
import 'package:fluxdo/providers/sidebar_sections_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _User extends CurrentUserNotifier {
  _User(this.user);

  final User? user;

  @override
  FutureOr<User?> build() => user;
}

SidebarSection _section(int id, String title, List<String> names) =>
    SidebarSection(
      id: id,
      title: title,
      links: [
        for (var i = 0; i < names.length; i++)
          SidebarSectionLink(
            id: id * 100 + i,
            name: names[i],
            value: '/t/${id * 100 + i}',
          ),
      ],
    );

class _Service implements DiscourseService {
  List<SidebarSection> remote = [];
  final listCalls = <bool>[];
  final updates = <Map<String, Object?>>[];
  final deleted = <int>[];
  int _nextId = 50;

  @override
  Future<List<SidebarSection>> getSidebarSections({
    bool background = false,
  }) async {
    listCalls.add(background);
    return remote;
  }

  @override
  Future<SidebarSection> createSidebarSection({
    required String title,
    required List<SidebarSectionLink> links,
  }) async {
    final created = SidebarSection(id: _nextId++, title: title, links: links);
    remote = [...remote, created];
    return created;
  }

  @override
  Future<SidebarSection> updateSidebarSection(
    int id, {
    required String title,
    required List<SidebarSectionLink> links,
    Iterable<SidebarSectionLink> removedLinks = const [],
  }) async {
    updates.add({
      'id': id,
      'title': title,
      'links': links.map((l) => l.name).toList(),
      'removed': removedLinks.map((l) => l.id).toList(),
    });
    return SidebarSection(id: id, title: title, links: links);
  }

  @override
  Future<void> deleteSidebarSection(int id) async => deleted.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Service service;
  late SharedPreferences prefs;

  Future<ProviderContainer> containerFor({User? user}) async {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(
          () => _User(user ?? User(id: 7, username: 'alice', trustLevel: 2)),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = _Service();
  });

  test('首次打开从服务端拉；再开先用本机缓存，后台静默刷新', () async {
    service.remote = [
      _section(1, '常用', ['A', 'B']),
    ];
    final first = await containerFor();
    final sections = await first.read(sidebarSectionsProvider.future);
    expect(sections.single.title, '常用');
    expect(service.listCalls, [false]);

    service.remote = [
      _section(1, '常用（网页改过）', ['A']),
    ];
    final second = await containerFor();
    final seen = <String>[];
    second.listen(sidebarSectionsProvider, (_, next) {
      final value = next.value;
      if (value != null) seen.add(value.single.title);
    }, fireImmediately: true);
    await second.read(sidebarSectionsProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect(seen.first, '常用', reason: '先出缓存');
    expect(service.listCalls, [false, true], reason: '后台刷新用静默请求');
    expect(
      second.read(sidebarSectionsProvider).value!.single.title,
      '常用（网页改过）',
    );
  });

  test('缓存按账号分开', () async {
    service.remote = [
      _section(1, 'alice 的', ['A']),
    ];
    final alice = await containerFor();
    await alice.read(sidebarSectionsProvider.future);

    service.remote = [
      _section(2, 'bob 的', ['B']),
    ];
    final bob = await containerFor(
      user: User(id: 8, username: 'bob', trustLevel: 1),
    );
    final sections = await bob.read(sidebarSectionsProvider.future);
    expect(sections.single.title, 'bob 的');
    expect(service.listCalls, [false, false], reason: '没用 alice 的缓存');
  });

  test('新建、保存、删除都写服务端并更新列表', () async {
    service.remote = [
      _section(1, '常用', ['A', 'B', 'C']),
    ];
    final container = await containerFor();
    final notifier = container.read(sidebarSectionsProvider.notifier);
    final existing = (await container.read(sidebarSectionsProvider.future))
        .single;

    final created = await notifier.create(
      title: '新的',
      links: const [SidebarSectionLink(name: 'X', value: '/tag/x')],
    );
    expect(container.read(sidebarSectionsProvider).value!.map((s) => s.title), [
      '常用',
      '新的',
    ]);

    await notifier.save(
      existing,
      title: '常用',
      links: [existing.links[2], existing.links[0]],
      removedLinks: [existing.links[1]],
    );
    expect(service.updates.single, {
      'id': 1,
      'title': '常用',
      'links': ['C', 'A'],
      'removed': [101],
    });
    expect(
      container
          .read(sidebarSectionsProvider)
          .value!
          .first
          .links
          .map((l) => l.name),
      ['C', 'A'],
    );

    await notifier.delete(created);
    expect(service.deleted, [created.id]);
    expect(container.read(sidebarSectionsProvider).value!.map((s) => s.title), [
      '常用',
    ]);
  });

  test('未登录时没有分区，也不请求', () async {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(() => _User(null)),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(sidebarSectionsProvider.future), isEmpty);
    expect(service.listCalls, isEmpty);
  });

  group('SidebarSection', () {
    test('解析网页接口的分区与链接，往返不丢字段', () {
      final section = SidebarSection.fromJson({
        'id': 42,
        'title': '我的常用',
        'public': false,
        'section_type': null,
        'links': [
          {
            'id': 1001,
            'name': '开发调优 :rocket:',
            'value': '/c/develop/4',
            'icon': 'code',
            'external': false,
            'segment': 'primary',
          },
        ],
      });
      expect(section.links.single.icon, 'code');
      expect(section.canEdit(isAdmin: false), isTrue);
      final again = SidebarSection.fromJson(section.toJson());
      expect(again.links.single, section.links.single);
    });

    test('公开分区只有管理员能改，社区分区谁都不能改', () {
      const public = SidebarSection(id: 1, title: 'p', links: [], public: true);
      const community = SidebarSection(
        id: 2,
        title: 'c',
        links: [],
        sectionType: 'community',
      );
      expect(public.canEdit(isAdmin: false), isFalse);
      expect(public.canEdit(isAdmin: true), isTrue);
      expect(community.canEdit(isAdmin: true), isFalse);
    });

    test('字数按码点算（与服务端一致）', () {
      expect(SidebarSectionLimits.length('😀😀'), 2);
    });
  });

  group('我的分类排序菜单', () {
    test('置顶 / 上移 / 下移，到头了不动', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = PinnedCategoriesNotifier(prefs)
        ..add(1)
        ..add(2)
        ..add(3);
      notifier.moveToTop(3);
      expect(notifier.state, [3, 1, 2]);
      notifier.moveUp(3);
      expect(notifier.state, [3, 1, 2]);
      notifier.moveDown(1);
      expect(notifier.state, [3, 2, 1]);
      notifier.moveDown(1);
      expect(notifier.state, [3, 2, 1]);
      notifier.moveUp(1);
      expect(notifier.state, [3, 1, 2]);
    });
  });
}
