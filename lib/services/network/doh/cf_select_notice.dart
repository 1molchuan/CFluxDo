/// 本地动态优选的首次说明（隐私说明 + 承诺）要不要弹
///
/// 按「主版本.次版本」记一次：同一个 major.minor 里只弹一次，
/// 升到新的 minor（功能可能变了）再弹一次。补丁版本（1.1.x）不重复打扰。
class CfSelectNotice {
  const CfSelectNotice._();

  /// 取版本号的「主.次」两段：
  /// '1.1.0-beta.3+2026' → '1.1'，'1.1.0' → '1.1'，'2' → '2'，空串 → ''
  static String majorMinor(String version) {
    // 先去掉预发布（-beta.3）和构建号（+2026），再按点拆
    final core = version.trim().split(RegExp(r'[+-]')).first;
    final parts = core.split('.').where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    return parts.take(2).join('.');
  }

  /// 没记录过，或记录的版本和当前不在同一个 major.minor，就要弹
  static bool shouldShow({
    required String currentVersion,
    required String? storedVersion,
  }) {
    if (storedVersion == null || storedVersion.trim().isEmpty) return true;
    return majorMinor(currentVersion) != majorMinor(storedVersion);
  }
}
