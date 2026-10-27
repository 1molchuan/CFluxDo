import 'dart:convert';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';

import '../site_context.dart';
import '../storage/secret_store.dart';
import '../storage/system_secret_store.dart';

/// 本机保存的一个论坛账号（多账号切换用）。
///
/// 这里只有展示用的信息；登录凭据（`_t` 等账号 cookie）单独存在该账号
/// 自己的安全存储槽里，见 [AccountStore]。
class SavedAccount {
  const SavedAccount({
    required this.userId,
    required this.username,
    this.name,
    this.avatarTemplate,
    required this.savedAt,
    this.needsLogin = false,
  });

  final int userId;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final DateTime savedAt;

  /// 切过去时服务端不认了（登录过期 / 在别处退出），要重新登录
  final bool needsLogin;

  /// 安全存储里凭据槽的账号维度（按站点区分，见 [SiteContext.accountKey]）
  String get accountKey => SiteContext.accountKey(username.toLowerCase());

  SavedAccount copyWith({
    String? name,
    String? avatarTemplate,
    DateTime? savedAt,
    bool? needsLogin,
  }) => SavedAccount(
    userId: userId,
    username: username,
    name: name ?? this.name,
    avatarTemplate: avatarTemplate ?? this.avatarTemplate,
    savedAt: savedAt ?? this.savedAt,
    needsLogin: needsLogin ?? this.needsLogin,
  );

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    userId: (json['userId'] as num).toInt(),
    username: json['username'] as String,
    name: json['name'] as String?,
    avatarTemplate: json['avatarTemplate'] as String?,
    savedAt:
        DateTime.tryParse(json['savedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    needsLogin: json['needsLogin'] == true,
  );

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    if (name != null) 'name': name,
    if (avatarTemplate != null) 'avatarTemplate': avatarTemplate,
    'savedAt': savedAt.toIso8601String(),
    if (needsLogin) 'needsLogin': true,
  };
}

/// 本机保存的账号列表与各账号的登录凭据。
///
/// 全部放系统安全存储（不进 SharedPreferences，数据备份也不会导出）；
/// 安全存储不可用时不降级到内存——宁可这个功能不可用，也不把凭据放在
/// 退出就丢、又让人以为存好了的地方。按站点分开（LINUX DO / IDC Flare
/// 各一份）。
class AccountStore {
  AccountStore({SecretStore? secretStore})
    : _secretStore = secretStore ?? SystemSecretStore.instance;

  final SecretStore _secretStore;

  /// 一台设备每个站点最多保存这么多个账号
  static const maxAccounts = 5;

  SecretKey get _indexKey =>
      SecretKey(namespace: 'accounts', name: SiteContext.storageKey('index'));

  SecretKey _cookiesKey(String accountKey) =>
      SecretKey(namespace: 'accounts', name: 'cookies', accountId: accountKey);

  Future<List<SavedAccount>> list() async {
    final raw = await _secretStore.read(_indexKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          SavedAccount.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeList(List<SavedAccount> accounts) => _secretStore.write(
    _indexKey,
    jsonEncode([for (final account in accounts) account.toJson()]),
  );

  /// 保存（或更新）一个账号及其凭据。已满且是新账号时抛 [AccountLimitException]。
  Future<void> save(SavedAccount account, List<CanonicalCookie> cookies) async {
    final accounts = [...await list()];
    final index = accounts.indexWhere((a) => a.userId == account.userId);
    if (index < 0 && accounts.length >= maxAccounts) {
      throw const AccountLimitException(maxAccounts);
    }
    await _secretStore.write(
      _cookiesKey(account.accountKey),
      jsonEncode([for (final cookie in cookies) cookie.toJson()]),
    );
    if (index < 0) {
      accounts.add(account);
    } else {
      accounts[index] = account;
    }
    await _writeList(accounts);
  }

  Future<List<CanonicalCookie>?> cookiesOf(SavedAccount account) async {
    final raw = await _secretStore.read(_cookiesKey(account.accountKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          CanonicalCookie.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> markNeedsLogin(int userId, {required bool needsLogin}) async {
    final accounts = [...await list()];
    final index = accounts.indexWhere((a) => a.userId == userId);
    if (index < 0 || accounts[index].needsLogin == needsLogin) return;
    accounts[index] = accounts[index].copyWith(needsLogin: needsLogin);
    await _writeList(accounts);
  }

  /// 从本机移除一个账号（凭据一并删掉；不会在服务端退出它）
  Future<void> remove(int userId) async {
    final accounts = [...await list()];
    final index = accounts.indexWhere((a) => a.userId == userId);
    if (index < 0) return;
    final removed = accounts.removeAt(index);
    await _secretStore.delete(_cookiesKey(removed.accountKey));
    await _writeList(accounts);
  }
}

class AccountLimitException implements Exception {
  const AccountLimitException(this.max);

  final int max;

  @override
  String toString() => 'AccountLimitException(max: $max)';
}
