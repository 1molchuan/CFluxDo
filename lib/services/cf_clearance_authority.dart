import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import 'cf_challenge_logger.dart';
import 'network/cookie/cookie_jar_service.dart';

/// cf_clearance 的会话级账本：在位值粘性判定 + 按 host 的可用性与冷却。
///
/// ## 一、在位值粘性（同步闸门）
///
/// **唯一规则：jar 里的当前 clearance 只要"还能用"（未过期、未临期、
/// 未被撞），任何同步来源不得用不同的值替换它。** 允许替换的条件：
/// jar 空 / 在位值过期 / 临期 / 在位值刚被撞（已死）/ 验证轮次定稿的值。
///
/// 为什么不判候选值（前三版的死穴）：
/// - 「撞一次就拉黑」：有效值在限流风暴里也会撞，误杀后恢复路径被堵，
///   2026-08-22 用户日志实锤为每次启动弹盾；
/// - 「同值撞两次才拉黑」：同一种误杀，只是概率低；
/// - 「按 expires 比新旧」：challenge page 与 Turnstile 两种签发渠道 TTL
///   形态不同，残留旧值的 expires 经常比新值更晚（2026-08-19 实锤），
///   该拦的时候放行。
/// 候选值死活客户端判不了；但「jar 里现在这枚值还活着吗」客户端判得出
/// （它自己刚被撞过，或即将过期）。判得了的才配做判定依据。
///
/// 行为口径（相对 0.2.26 的唯一区别是「sync 何时允许替换」）：
/// - 撞盾（403/429 不论）→ 及时过盾（用户的明确公理：过盾即恢复）；
/// - 过盾后新值自动成为在位值 → 残留旧副本/Turnstile pre-clearance 一律
///   无法顶替（2026-08-19「过一次盾只管一次」循环从机制上消失）；
/// - jar 空（验证取消/删除）→ 一切 sync 放行，恢复路径与 0.2.26 同样畅通；
/// - 在位值被撞 → 放开替换，Turnstile 最新铸值可无缝补位（无盾换届）。
///
/// ## 二、按 host 的可用性账本
///
/// cf_clearance 是 `.linux.do` 域 cookie，主站与 credit/cdk/connect 等子域
/// 共用 jar 里的同一枚值，但各 host 的 CF 规则未必一致：同一枚值可能在
/// 主站有效、在 cdk 被撞。此前「能不能用」散在四处、口径各异（闸门的
/// 30 分钟临期、BrowserTrust 原生预加载的 10 分钟与请求门的 30 秒两份
/// 几乎相同的判定、只在 bootstrap 被挡时才记的 2 分钟拒绝窗口、验证服务
/// 的全局冷却），且全部钉死在主站——一个子域上定稿值无效，整个 App 跟着
/// 冷却 60 秒。现在由本账本按 host 记录被撞、被拒、冷却，[status] 按用途
/// 给出带原因的「能不能用」，BrowserTrust 与续期服务只读它。
///
/// 冷却口径：
/// - 验证本身连续失败（取消/超时/没落值）是**全站**问题（验证页在主站），
///   记在主站，所有 host 都不再起验证；
/// - 「验证通过、定稿值进了 jar，这个 host 的重放仍被撞」是**该 host**
///   确定性无效，只冷却该 host。
class CfClearanceAuthority {
  CfClearanceAuthority._();
  static final CfClearanceAuthority instance = CfClearanceAuthority._();

  static const String cookieName = 'cf_clearance';

  /// 换届窗口：在位值剩余有效期小于该值时允许替换（自然换届，零弹盾）。
  static const Duration rotationWindow = Duration(minutes: 30);

  /// 服务端以 CF 拒绝（WebView session bootstrap 被挡等）之后，在此窗口内
  /// 即使本地值的有效期还够，也视为不可信——避免冷启动盲信本地值再撞墙。
  /// jar 换上了别的值则提前解除。
  static const Duration rejectionTtl = Duration(minutes: 2);

  /// 验证连续失败达到该次数后进入冷却。
  static const int maxVerifyFailures = 3;

  /// 验证连续失败后的冷却时长。
  static const Duration verifyFailureCooldown = Duration(seconds: 30);

  /// 定稿值对某 host 确定性无效后的冷却时长（典型：Dio 与 WebView 出口
  /// IP 不一致，clearance 绑定了另一侧的 IP，重复验证不可能成功）。
  static const Duration ineffectiveCooldown = Duration(seconds: 60);

  /// 主站 host（验证页所在、jar 读写口径的默认 host）。
  static String get mainHost => CookieJarService.appBaseHost;

  /// 最近一次撞盾时 jar 里的值（= 已死的在位值，不分 host）。
  /// 换届闸门只看这一个：撞了就过盾，没有语义要判，不需要计数。
  String? _lastChallengedValue;

  /// 本会话内在任意 host 上被撞过的值（归一化，有界）。
  final Set<String> _challengedValues = <String>{};

  /// 本会话内从 WebView 回读到过的 cf_clearance 值（归一化，有界）。
  /// 用于区分「本会话新铸值」与「残留旧值」：闸门决定不变，只影响日志口径，
  /// 让线上日志能看出被挡下的是哪一类候选值。
  final Set<String> _observedWebViewValues = <String>{};

  /// 每个 host 的被撞值、被拒时刻、冷却与失败计数。
  final Map<String, _HostLedger> _hosts = <String, _HostLedger>{};

  static const int _maxTrackedValues = 16;

  /// 验证轮次正在落值的定稿值（归一化）。它是本会话最新、经挑战确认的
  /// 值：即便验证期间有别的同步往（被清空的）jar 里写过一枚"健康"值，
  /// 也要让它继位。只在落值那一次同步期间有效。
  String? _verifiedSuccessor;

  _HostLedger _host(String host) =>
      _hosts.putIfAbsent(_normalizeHost(host), _HostLedger.new);

  static String _normalizeHost(String host) => host.trim().toLowerCase();

  /// 验证轮次落值前登记定稿值，落值结束后传 null 清除。
  void expectVerifiedSuccessor(String? value) {
    final normalized = _normalize(value ?? '');
    _verifiedSuccessor = normalized.isEmpty ? null : normalized;
  }

  // ---------------------------------------------------------------------------
  // 被撞 / 被拒
  // ---------------------------------------------------------------------------

  /// 撞盾时登记：请求实际携带的 cf_clearance 已被 CF 挑战 = 在位值已死，
  /// 此后 sync 可以替换它（过盾新值继位，或 Turnstile 新铸值无缝补位）。
  /// [host] 是撞盾请求的 host（缺省为主站）。
  void noteIncumbentChallenged(String? value, {String? host}) {
    final normalized = _normalize(value ?? '');
    if (normalized.isEmpty) return;
    _remember(_challengedValues, normalized);
    _remember(_host(host ?? mainHost).challenged, normalized);
    if (normalized == _lastChallengedValue) return;
    _lastChallengedValue = normalized;
    debugPrint('[CfClearanceAuthority] 在位 cf_clearance 被撞，放开换届');
    CfChallengeLogger.log(
      '[AUTHORITY] incumbent challenged (${normalized.length} chars, '
      'host=${host ?? mainHost}), rotation window open',
    );
  }

  /// 该值是否在本会话内被撞过（已知死值）。给了 [host] 只看该 host。
  bool isKnownChallenged(String? value, {String? host}) {
    final normalized = _normalize(value ?? '');
    if (normalized.isEmpty) return false;
    if (host == null) return _challengedValues.contains(normalized);
    return _hosts[_normalizeHost(host)]?.challenged.contains(normalized) ??
        false;
  }

  /// 服务端以 CF 拒绝了 [host] 上的 clearance（如 WebView session bootstrap
  /// 被挡）。[value] 是被拒时 jar 里的值（不知道传 null）：jar 换上别的值
  /// 后拒绝随之失效；不知道是哪枚时整个窗口内都不可信。
  void noteRejected(String host, {String? value}) {
    final record = _host(host);
    record.rejectedAt = _now();
    final normalized = _normalize(value ?? '');
    record.rejectedValue = normalized.isEmpty ? null : normalized;
    CfChallengeLogger.log(
      '[AUTHORITY] clearance rejected by server: host=$host '
      '(value=${normalized.isEmpty ? 'unknown' : '${normalized.length} chars'})',
      level: 'warning',
    );
  }

  /// 解除 [host] 的拒绝记录（拿到了新 clearance）。
  void clearRejection(String host) {
    final record = _hosts[_normalizeHost(host)];
    record?.rejectedAt = null;
    record?.rejectedValue = null;
  }

  // ---------------------------------------------------------------------------
  // 可用性
  // ---------------------------------------------------------------------------

  /// jar 里的 cf_clearance 对 [host] 来说能不能用于 [purpose]，并给出原因。
  Future<CfClearanceStatus> status(
    String host, {
    required CfClearancePurpose purpose,
  }) async {
    final cookie = await _readCanonical(host);
    final value = _normalize(cookie?.value ?? '');
    final expiresAt = cookie?.expiresAt;
    final now = _now();
    final ttl = expiresAt?.difference(now);

    final present =
        value.isNotEmpty &&
        CookieJarService.matchesAppHost(cookie?.domain) &&
        (expiresAt == null || expiresAt.isAfter(now));

    CfClearanceStatus verdict(CfClearanceVerdict v) => CfClearanceStatus(
      verdict: v,
      present: present,
      value: value.isEmpty ? null : value,
      domain: cookie?.domain,
      expiresAt: expiresAt,
      ttl: ttl,
    );

    final record = _hosts[_normalizeHost(host)];
    // 1. 服务端刚拒绝过（且 jar 里还是那枚值，或不知道是哪枚）
    final rejectedAt = record?.rejectedAt;
    if (rejectedAt != null) {
      if (now.difference(rejectedAt) >= rejectionTtl) {
        record!.rejectedAt = null;
        record.rejectedValue = null;
      } else if (record!.rejectedValue == null ||
          record.rejectedValue == value) {
        return verdict(CfClearanceVerdict.recentlyRejected);
      }
    }
    // 2. 没有 / 不属于本站 / 已过期
    if (cookie == null || value.isEmpty) {
      return verdict(CfClearanceVerdict.missing);
    }
    if (!CookieJarService.matchesAppHost(cookie.domain)) {
      return verdict(CfClearanceVerdict.foreignDomain);
    }
    if (expiresAt != null && !expiresAt.isAfter(now)) {
      return verdict(CfClearanceVerdict.expired);
    }
    // 3. 这枚值在该 host 上被撞过
    if (record?.challenged.contains(value) ?? false) {
      return verdict(CfClearanceVerdict.challenged);
    }
    // 4. 剩余有效期不够这个用途（无 expires 的会话形态视为够用）
    if (ttl != null && ttl < purpose.minTtl) {
      return verdict(CfClearanceVerdict.expiring);
    }
    return verdict(CfClearanceVerdict.usable);
  }

  // ---------------------------------------------------------------------------
  // 冷却
  // ---------------------------------------------------------------------------

  /// [host] 当前是否处于冷却：它自己的冷却，或全站（主站）的验证冷却。
  bool isCoolingDown(String host) {
    final normalized = _normalizeHost(host);
    if (_coolingDown(normalized)) return true;
    return normalized != mainHost && _coolingDown(mainHost);
  }

  bool _coolingDown(String host) {
    final record = _hosts[host];
    final until = record?.cooldownUntil;
    if (until == null) return false;
    if (_now().isAfter(until)) {
      record!.cooldownUntil = null;
      return false;
    }
    return true;
  }

  /// [host] 自己的冷却截止时刻（诊断用；判定请用 [isCoolingDown]）。
  DateTime? cooldownUntil(String host) =>
      _hosts[_normalizeHost(host)]?.cooldownUntil;

  /// [host] 的连续失败次数（诊断用）。
  int consecutiveFailures(String host) =>
      _hosts[_normalizeHost(host)]?.consecutiveFailures ?? 0;

  /// 记录一次验证失败（全站口径，记在主站），连续达到上限后进入冷却。
  ///
  /// [round] 传入失败的验证轮次号：同一轮只记一次——多个并发请求撞盾会
  /// 合流到同一轮验证，不去重会把一次失败放大成 N 次，瞬间打满阈值
  /// （实测：启动时五个首屏请求同时撞盾，9 秒后自愈，用户却被冷却 +
  /// 切兼容询问打断）。不传则按独立失败计数。
  void recordVerifyFailure({int? round}) {
    final record = _host(mainHost);
    if (round != null) {
      if (record.failureCountedRound == round) {
        debugPrint('[CfChallenge] 轮次 $round 的失败已记过，跳过重复计数');
        return;
      }
      record.failureCountedRound = round;
    }
    record.consecutiveFailures++;
    if (record.consecutiveFailures >= maxVerifyFailures) {
      record.cooldownUntil = _now().add(verifyFailureCooldown);
      debugPrint(
        '[CfChallenge] 连续失败 ${record.consecutiveFailures} 次，'
        '进入 ${verifyFailureCooldown.inSeconds}s 冷却期',
      );
      CfChallengeLogger.logCooldown(
        entering: true,
        until: record.cooldownUntil,
      );
    } else {
      debugPrint(
        '[CfChallenge] 验证失败 ${record.consecutiveFailures}/'
        '$maxVerifyFailures，允许重试',
      );
    }
  }

  /// 验证通过、定稿值进了 jar，[host] 的重放却仍被撞：只冷却该 host。
  ///
  /// 不能走失败计数——否则每次撞盾都会拉起一轮完整验证，形成删 cookie →
  /// 验证 → 再撞的无限循环。以前这里冷却的是全站：credit/cdk 子域上一次
  /// 无效，整个 App 的请求都跟着拒 60 秒。
  void startIneffectiveCooldown(String host) {
    final record = _host(host);
    record.consecutiveFailures = maxVerifyFailures;
    record.cooldownUntil = _now().add(ineffectiveCooldown);
    debugPrint(
      '[CfChallenge] 验证完成但 clearance 对 $host 无效，'
      '进入 ${ineffectiveCooldown.inSeconds}s 冷却期',
    );
    CfChallengeLogger.logCooldown(entering: true, until: record.cooldownUntil);
  }

  /// 清空所有 host 的冷却与失败计数（验证通过、用户主动验证时）。
  void resetCooldown() {
    for (final record in _hosts.values) {
      record.cooldownUntil = null;
      record.consecutiveFailures = 0;
      // 去重标记随计数一起清:下一轮失败要能重新记账
      record.failureCountedRound = null;
    }
    CfChallengeLogger.logCooldown(entering: false);
  }

  // ---------------------------------------------------------------------------
  // WebView 观察值
  // ---------------------------------------------------------------------------

  /// 登记一次 WebView 回读到的 cf_clearance 值（每次 sync 都调用）。
  void noteWebViewValueObserved(String? value) {
    final normalized = _normalize(value ?? '');
    if (normalized.isEmpty) return;
    _remember(_observedWebViewValues, normalized);
  }

  /// 该值是否在本会话内从 WebView 回读到过。
  bool hasObservedWebViewValue(String? value) {
    final normalized = _normalize(value ?? '');
    return normalized.isNotEmpty && _observedWebViewValues.contains(normalized);
  }

  /// 有界集合：超出上限时淘汰最早登记的值（Set 保持插入顺序）。
  static void _remember(Set<String> set, String value) {
    if (set.contains(value)) return;
    if (set.length >= _maxTrackedValues) set.remove(set.first);
    set.add(value);
  }

  // ---------------------------------------------------------------------------
  // 同步闸门
  // ---------------------------------------------------------------------------

  /// sync 闸门判定：候选值 [candidateValue] 是否允许替换 jar 当前值。
  Future<CfClearanceReplaceDecision> evaluateReplacement(
    String candidateValue,
  ) async {
    final candidate = _normalize(candidateValue);
    if (candidate.isEmpty) return CfClearanceReplaceDecision.allow;

    final current = await _readCanonical(mainHost);
    final currentValue = _normalize(current?.value ?? '');

    // 1. jar 空：恢复路径全开（验证取消/删除后的写回与 0.2.26 一致）。
    if (currentValue.isEmpty) return CfClearanceReplaceDecision.allow;

    // 2. 同值：幂等，无需写入。
    if (candidate == currentValue) {
      return CfClearanceReplaceDecision.skipSameValue;
    }

    // 2.5 验证轮次定稿的值：经挑战确认的最新值，直接继位。
    if (candidate == _verifiedSuccessor) return CfClearanceReplaceDecision.allow;

    // 3. 在位值过期/临期：自然换届窗口，放行（新铸值无缝继位）。
    // 只做时刻比较,与 DateTime 的 UTC/本地标记无关,不需要 toLocal
    final expires = current?.expiresAt;
    if (expires != null) {
      final now = _now();
      if (!expires.isAfter(now)) return CfClearanceReplaceDecision.allow;
      if (expires.difference(now) <= rotationWindow) {
        return CfClearanceReplaceDecision.allow;
      }
    }

    // 4. 在位值刚被撞（已死，不论在哪个 host 被撞——jar 里只有这一枚）：放开替换。
    final challenged = _lastChallengedValue;
    if (challenged != null && challenged == currentValue) {
      return CfClearanceReplaceDecision.allow;
    }

    // 5. 在位值健康：拒绝任何异值顶替。
    return CfClearanceReplaceDecision.skipHealthyIncumbent;
  }

  /// 从请求的 Cookie header 中提取 cf_clearance 值（可能为 null）。
  static String? extractFromCookieHeader(String? cookieHeader) {
    if (cookieHeader == null || cookieHeader.isEmpty) return null;
    final value = _clearancePattern.firstMatch(cookieHeader)?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static final RegExp _clearancePattern = RegExp(
    r'(?:^|;\s*)cf_clearance=([^;]*)',
  );

  /// 两个 cf_clearance 值归一化后是否相同（请求头里是解码形态，jar 里可能
  /// 带编码，直接字符串比较会误判为不同）。任一为空视为不同。
  static bool isSameValue(String? a, String? b) {
    final left = _normalize(a ?? '');
    final right = _normalize(b ?? '');
    if (left.isEmpty || right.isEmpty) return false;
    return left == right;
  }

  /// 归一化：请求头里的值是 [CookieValueCodec.decode] 后的形态（见
  /// AppCookieManager），WebView 回读的也是解码形态；jar 存储可能带编码。
  /// 两侧统一 decode 一次（cf_clearance 值是 URL-safe 字符，重复 decode 幂等）。
  static String _normalize(String value) => CookieValueCodec.decode(value);

  /// 登出/换账号时清空：值的标记随登录会话失效（冷却与拒绝窗口按时间
  /// 自然过期，不随账号变化）。
  void reset() {
    _lastChallengedValue = null;
    _verifiedSuccessor = null;
    _challengedValues.clear();
    _observedWebViewValues.clear();
    for (final record in _hosts.values) {
      record.challenged.clear();
    }
  }

  /// 测试用：清空全部状态（含冷却与拒绝记录）。
  @visibleForTesting
  void debugResetAll() {
    reset();
    _hosts.clear();
  }

  // ---------------------------------------------------------------------------
  // jar 读取与时钟（测试可注入）
  // ---------------------------------------------------------------------------

  static Future<CanonicalCookie?> _defaultReader(String host) =>
      CookieJarService().getCanonicalCookie(cookieName, host: host);

  /// 测试用：替换 jar 读取器（不区分 host）。
  @visibleForTesting
  Future<CanonicalCookie?> Function()? debugCookieReader;

  /// 测试用：替换时钟。
  @visibleForTesting
  DateTime Function()? debugNow;

  DateTime _now() => (debugNow ?? DateTime.now)();

  Future<CanonicalCookie?> _readCanonical(String host) {
    final reader = debugCookieReader;
    if (reader != null) return reader();
    return _defaultReader(host);
  }
}

/// 单个 host 的记录。
class _HostLedger {
  /// 在该 host 上被撞过的值（归一化，有界）。
  final Set<String> challenged = <String>{};

  /// 服务端最近一次以 CF 拒绝的时刻与当时 jar 里的值（null = 不知道）。
  DateTime? rejectedAt;
  String? rejectedValue;

  DateTime? cooldownUntil;
  int consecutiveFailures = 0;

  /// 已被记过失败的轮次号，防止同一轮被多个等待者重复计数。
  int? failureCountedRound;
}

/// sync 闸门判定结果（见 [CfClearanceAuthority.evaluateReplacement]）。
enum CfClearanceReplaceDecision {
  /// 放行：jar 空 / 在位值过期 / 临期 / 在位值刚被撞 / 验证定稿值。
  allow,

  /// 候选值与在位值相同：幂等，无需写入。
  skipSameValue,

  /// 在位值健康且未被撞：拒绝异值顶替（过盾成果保护）。
  skipHealthyIncumbent,
}

/// 读 cf_clearance 的用途。不同用途需要的剩余有效期不同，门槛统一定义在
/// 这里（以前 BrowserTrust 里是两份几乎相同的判定，各写一个常量）。
enum CfClearancePurpose {
  /// 冷启动直接用原生链路预加载首页：至少还剩 10 分钟，否则走启动 WebView
  /// （预加载期间过期会撞盾，启动反而更慢）。
  nativePreload(Duration(minutes: 10)),

  /// 启动/恢复后首波业务请求的信任门：至少还剩 30 秒。
  requestGate(Duration(seconds: 30)),

  /// 续期服务读取当前值：只要没过期。
  refresh(Duration.zero);

  const CfClearancePurpose(this.minTtl);

  final Duration minTtl;
}

/// [CfClearanceAuthority.status] 的判定。
enum CfClearanceVerdict {
  usable,

  /// jar 里没有。
  missing,

  /// jar 里那枚不属于本站域名。
  foreignDomain,

  /// 已过期。
  expired,

  /// 剩余有效期不够这个用途。
  expiring,

  /// 这枚值在该 host 上被撞过（本会话）。
  challenged,

  /// 服务端刚以 CF 拒绝过（窗口内）。
  recentlyRejected,
}

/// 「能不能用」的答案与依据。
class CfClearanceStatus {
  const CfClearanceStatus({
    required this.verdict,
    required this.present,
    this.value,
    this.domain,
    this.expiresAt,
    this.ttl,
  });

  final CfClearanceVerdict verdict;
  final String? value;
  final String? domain;
  final DateTime? expiresAt;
  final Duration? ttl;

  /// jar 里有一枚属于本站、未过期的值（不论是否被撞/被拒/临期）。
  final bool present;

  bool get usable => verdict == CfClearanceVerdict.usable;

  @override
  String toString() =>
      '${verdict.name} ttl=${ttl?.inSeconds ?? '-'}s '
      'expires=${expiresAt?.toIso8601String() ?? '-'} domain=${domain ?? '-'}';
}
