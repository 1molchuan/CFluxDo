import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../cf_challenge_logger.dart';
import '../../cf_clearance_authority.dart';
import '../exceptions/api_exception.dart';
import '../flux_request_spec.dart';
import 'cf_challenge_classifier.dart';
import 'cf_round_outcome.dart';

/// 重放端口：以 jar 当前 Cookie 头把请求再发一次（调用方已打好防环标记）。
///
/// 返回的响应可能本身就是挑战页（调用方的 validateStatus 放行了 4xx），
/// 是否仍被撞由 [CfChallengeRecovery] 用统一分类器判定。
abstract interface class CfReplayPort {
  Future<Response<dynamic>> replay(RequestOptions options);
}

/// cf_clearance 端口：读 jar 当前值，以及把 WebView 持有的另一枚值换进 jar。
abstract interface class CfClearancePort {
  Future<String?> currentInJar();

  /// WebView 若持有一枚与 [challenged] 不同、且本会话在 [host] 上未被撞过
  /// 的值，经权威闸门换进 jar 并返回它；没有可换的值或闸门未采纳返回 null。
  Future<String?> swapInWebViewCandidate({
    required String? challenged,
    required String host,
  });
}

/// 验证轮次端口。
abstract interface class CfRoundPort {
  /// 是否有一轮验证正在进行（含验证页析构冷却期）。
  bool get isVerifying;

  /// 用户是否允许撞盾时自动弹验证。
  bool get autoVerifyEnabled;

  /// [host] 当前是否处于冷却（冷却期内不再起验证）。
  bool isCoolingDown(String host);

  /// 加入进行中的一轮或发起新一轮，返回这一轮的结果。
  Future<CfRoundOutcome> acquire(CfVerifyMode mode);

  /// 验证通过、定稿值也进了 jar，[host] 的重放却仍被撞：对它确定性无效。
  void noteIneffective(String host);
}

/// 会话级兼容模式端口（改用浏览器网络栈发主站请求）。
abstract interface class CfCompatPort {
  /// 该请求能否走 WebView 适配器。
  bool canUse(RequestOptions options);

  /// 已开启或用户同意开启 → 打开会话兼容并返回 true。
  Future<bool> enable();

  /// 兼容重放失败：撤销会话兼容（用户持久开启的不动）。
  void rollback();

  /// 本次会话是否已确认原生链路不被信任（验证通过后重放仍被拦、已改用
  /// 浏览器网络栈）。用户在设置里常开的兼容模式不算。
  bool get nativeUntrusted;
}

/// 恢复过程中需要告诉用户的事（文案与 toast 节流由实现方负责）。
enum CfRecoveryNotice {
  /// 操作被安全验证拦截（冷却中）。
  blockedByChallenge,

  /// 无法打开验证页。
  cannotOpenVerifyPage,

  /// 验证完成但对请求无效。
  notEffective,

  /// 验证未完成（取消/超时）。
  verifyIncomplete,

  /// 已切到本次会话的兼容模式（提示，非错误）。
  compatEnabled,
}

typedef CfRecoveryNotifier = void Function(CfRecoveryNotice notice);

/// 过盾恢复的结果。
sealed class CfRecoveryResult {
  const CfRecoveryResult();
}

/// 拿到了可以交给调用方的响应。
final class CfRecovered extends CfRecoveryResult {
  const CfRecovered(this.response);

  final Response<dynamic> response;
}

/// 恢复失败：[error] 原样交给调用方（CF 原因时 error 里是 [CfChallengeException]）。
final class CfRecoveryFailed extends CfRecoveryResult {
  const CfRecoveryFailed(this.error);

  final DioException error;
}

/// 单个撞盾请求的恢复流程。
///
/// 此前整段写在 CfChallengeInterceptor.onError 里（约 450 行，四个重放点、
/// 四处 Cookie 头解析、「换值重放一次」写了两遍）。现在拦截器只做 Dio 适配，
/// 顺序与副作用全部在这里，经四个小端口与外界交互，可以用脚本化的假重放测：
///
/// 1. 过期 403：请求携带的值已不是 jar 当前值 → 用当前值重放一次；
/// 2. 登记在位值被撞（**必须先于任何新值落 jar**，否则权威闸门会以
///    「在位值健康」为由挡掉新值）；
/// 3. 换值重放：WebView 持有另一枚未被撞过的值 → 换进 jar 重放一次
///    （验证进行中不做，避免与验证页抢写）；
/// 4. 发起/加入一轮验证，通过后重放；用户可见请求仍被撞时再验证一轮
///    （结果已由验证页交来的请求直接交回，见 [FluxRequestKeys.satisfiedProbe]）；
/// 5. 仍被撞：可走 WebView 的用户可见请求询问切兼容模式并重放，失败回滚；
///    否则记该 host 确定性无效（冷却）。
///
/// 不进 RecoveryCoordinator 的理由见 CfChallengeInterceptor 的文档注释。
class CfChallengeRecovery {
  CfChallengeRecovery({
    required this.replay,
    required this.clearance,
    required this.round,
    required this.compat,
    CfClearanceAuthority? ledger,
    CfRecoveryNotifier? notify,
  }) : ledger = ledger ?? CfClearanceAuthority.instance,
       _notify = notify;

  final CfReplayPort replay;
  final CfClearancePort clearance;
  final CfRoundPort round;
  final CfCompatPort compat;
  final CfClearanceAuthority ledger;
  final CfRecoveryNotifier? _notify;

  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

  /// 撞盾时是否给用户即时提示：静默请求不提示；显式指定以指定为准；
  /// 否则写操作提示、页面数据请求交给 ErrorView。
  static bool shouldShowActionPrompt(RequestOptions options) {
    final spec = options.spec;
    if (spec.isSilent) return false;
    if (spec.hasExplicitErrorToast) return spec.showErrorToast;
    return _mutationMethods.contains(options.method.toUpperCase());
  }

  static String requestMode(RequestOptions options) {
    if (options.spec.isSilent) return 'silent';
    return shouldShowActionPrompt(options) ? 'action' : 'data';
  }

  /// 请求实际携带的 cf_clearance（Cookie 头里的解码形态）。
  static String? carriedClearance(RequestOptions options) =>
      CfClearanceAuthority.extractFromCookieHeader(
        options.headers['Cookie']?.toString() ??
            options.headers['cookie']?.toString(),
      );

  Future<CfRecoveryResult> recover(DioException err) async {
    final original = err.requestOptions;
    final host = original.uri.host.toLowerCase();
    final label = '${original.method.toUpperCase()} ${original.uri}';
    final mode = requestMode(original);
    final actionPrompt = shouldShowActionPrompt(original);
    final isSilent = original.spec.isSilent;

    // 1. 过期 403 直接换 cookie 重放：本次请求携带的值若已不是 jar 当前值
    //    （请求在途期间另一轮验证换上了新值，或排队请求仍带着验证前的旧
    //    Cookie 头），这个 403 针对的是旧值，jar 里的新值很可能本来就能过。
    final carried = carriedClearance(original);
    final current = await clearance.currentInJar();
    final carriedIsStale =
        current != null &&
        current.isNotEmpty &&
        !CfClearanceAuthority.isSameValue(carried, current);
    if (carriedIsStale) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] Carried cf_clearance is stale '
        '(carried=${carried?.length ?? 0} chars, '
        'current=${current.length} chars), replaying with current: $label',
      );
      final attempt = await _attempt(_replayOptions(original));
      switch (attempt) {
        case _Succeeded(:final response):
          return CfRecovered(response);
        case _Failed(:final error):
          // 不是 CF 问题（网络错误、其他状态码）：如实返回，不再发起验证
          return CfRecoveryFailed(error);
        case _StillChallenged(:final statusCode):
          CfChallengeLogger.log(
            '[INTERCEPTOR] Replay with current cf_clearance still '
            'challenged ($statusCode), falling back to verify',
          );
      }
    }

    // 2. 登记在位值被撞：本次请求（或刚才的重放）实际携带的值已被 CF 挑战，
    //    打开换届窗口——之后的同步才能用新值替换它。不分 403/429。
    final challenged = carriedIsStale ? current : carried;
    ledger.noteIncumbentChallenged(challenged, host: host);

    // 3. 撞盾先换值重放：典型是站点在 WebView 里刚签了新值，但同步闸门因
    //    在位值当时还健康把它挡在 jar 外。实测可把 3～6 秒的恢复缩到一个
    //    请求往返。验证进行中不做（验证页自己会落值，避免两边抢写）。
    if (!round.isVerifying) {
      final swapped = await clearance.swapInWebViewCandidate(
        challenged: challenged,
        host: host,
      );
      if (swapped != null) {
        CfChallengeLogger.log(
          '[INTERCEPTOR] Swapped in WebView cf_clearance '
          '(challenged=${challenged?.length ?? 0} chars, '
          'webview=${swapped.length} chars), replaying: $label',
        );
        final attempt = await _attempt(_replayOptions(original));
        switch (attempt) {
          case _Succeeded(:final response):
            return CfRecovered(response);
          case _Failed(:final error):
            return CfRecoveryFailed(error);
          case _StillChallenged(:final statusCode):
            // 换上的值也被撞：登记为已死，继续走验证流程
            ledger.noteIncumbentChallenged(swapped, host: host);
            CfChallengeLogger.log(
              '[INTERCEPTOR] Replay with WebView cf_clearance still '
              'challenged ($statusCode), falling back to verify',
            );
        }
      }
    }

    if (!round.autoVerifyEnabled) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] Auto verify disabled, rejecting: $label mode=$mode',
      );
      return _fail(original, CfChallengeException(autoVerifyDisabled: true));
    }

    // 注：这里刻意**不**提前判"没有前台 UI"。启动早期 navigator context
    // 也是 null，提前 reject 会毁掉"启动时撞盾、等 context 就绪后补弹验证"
    // 这条路径。无 UI 由验证入口自己的 context 等待上限收口（noUi）。
    if (round.isCoolingDown(host)) {
      debugPrint('[Dio] CF Challenge in cooldown, rejecting request');
      CfChallengeLogger.log(
        '[INTERCEPTOR] Cooldown after 403: $label mode=$mode',
      );
      if (actionPrompt) _notify?.call(CfRecoveryNotice.blockedByChallenge);
      return _fail(original, CfChallengeException(inCooldown: true));
    }

    // 本次会话已确认原生链路不被信任（主站已改走浏览器网络栈），而这个子域
    // 请求（LDC/CDK 等）走不了浏览器网络栈：再验证一轮，重放照样被拦，只会
    // 反复弹验证页。直接交回，由业务卡片给出「在浏览器中打开」。
    if (host != CfClearanceAuthority.mainHost &&
        compat.nativeUntrusted &&
        !compat.canUse(original)) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] Native stack untrusted this session and the request '
        'cannot use the browser stack, not verifying: $label mode=$mode',
      );
      if (actionPrompt) _notify?.call(CfRecoveryNotice.blockedByChallenge);
      return _fail(original, CfChallengeException(nativeUntrusted: true));
    }

    // 4. 静默请求只在后台尝试验证；页面数据/操作请求先后台静默尝试一个
    //    宽限期，多数非交互式挑战会在这段时间内自动通过，过不了再转前台。
    var outcome = await round.acquire(
      isSilent ? CfVerifyMode.background : CfVerifyMode.silentFirst,
    );

    // 验证「通过」但重放仍被撞时，用户可见请求再给一轮验证机会（只一轮）。
    // 实测（2026-10-13，元宇宙「我的服务」开启失败）这类值多是挑战流程
    // 被提前收口的半成品，下一轮就能铸出有效值；以前直接熔断 60s 冷却。
    var reverified = false;
    // 本次恢复里是否已经试过兼容模式：试过（含用户拒绝）就不再问第二次，
    // 让用户在做完第二轮验证后不会再被打断一遍。
    var triedCompat = false;

    while (true) {
      if (outcome case CfRoundFailed(:final reason)) {
        return _roundFailed(
          original,
          reason,
          label: label,
          mode: mode,
          actionPrompt: actionPrompt,
        );
      }

      // 各自重放自己的原始请求（每个请求 URL/参数不同，无法共享）
      final retryOptions = _replayOptions(original);
      final attempt = await _attempt(retryOptions);
      final _StillChallenged stillChallenged;
      switch (attempt) {
        case _Succeeded(:final response):
          return CfRecovered(response);
        case _Failed(:final error):
          // 验证已通过，重放失败是其他原因：传递实际错误以便排查
          return CfRecoveryFailed(error);
        case _StillChallenged():
          stillChallenged = attempt;
      }

      // 调用方要的结果已由验证页交来（启动预加载拿到了验证页停留的首页）：
      // 原错误交回，由调用方按已拿到处理；不再重验、询问兼容或冷却。
      if (original.spec.isSatisfiedElsewhere) {
        CfChallengeLogger.log(
          '[INTERCEPTOR] Replay still challenged, but the result was supplied '
          'by the verification page: $label',
        );
        return CfRecoveryFailed(stillChallenged.error);
      }

      // 刚由用户亲手过的挑战，原生重放仍被拦：同样的挑战大概率还要用户
      // 再点一次，而浏览器网络栈刚刚正是"能过"的那条链路。先问兼容模式；
      // 用户拒绝、或兼容重放也没过，再回到原有的一次重验。
      final interactivePass =
          outcome is CfRoundPassed && outcome.interactionRequired;
      if (!isSilent &&
          !reverified &&
          !triedCompat &&
          interactivePass &&
          compat.canUse(retryOptions)) {
        triedCompat = true;
        // 这枚值原生确定用不了：登记为已撞，续期服务随后在 WebView 里铸出的
        // Turnstile 值才能顶替它（2026-10-26 实测勾选框签的值原生 403、
        // 续期铸的值原生 200），否则走兼容后 jar 里一直是这枚死值。
        ledger.noteIncumbentChallenged(stillChallenged.carried, host: host);
        if (await compat.enable()) {
          retryOptions.extra.remove(FluxRequestKeys.skipWebViewAdapter);
          final fallback = await _attempt(retryOptions);
          if (fallback case _Succeeded(:final response)) {
            _notify?.call(CfRecoveryNotice.compatEnabled);
            CfChallengeLogger.log(
              '[INTERCEPTOR] Interactive-pass clearance rejected by native '
              'stack; session WebView fallback succeeded',
            );
            return CfRecovered(response);
          }
          compat.rollback();
          if (fallback case _Failed(:final error)) {
            CfChallengeLogger.log(
              '[INTERCEPTOR] Session WebView fallback after interactive '
              'pass failed: $error',
              level: 'warning',
            );
            return CfRecoveryFailed(error);
          }
        }
      }

      if (!isSilent && !reverified && !round.isCoolingDown(host)) {
        reverified = true;
        // 刚定稿的值已确认对 Dio 无效：登记为已撞，放开换届，下一轮
        // 验证铸出的新值才能过闸门进 jar。
        ledger.noteIncumbentChallenged(stillChallenged.carried, host: host);
        CfChallengeLogger.log(
          '[INTERCEPTOR] Verified clearance rejected on retry '
          '(${stillChallenged.statusCode}), re-verifying once: $label',
          level: 'warning',
        );
        outcome = await round.acquire(CfVerifyMode.silentFirst);
        continue;
      }

      // 5. 拿到新值后原生链路仍被拒：问题不只是 Cookie，而是当前原生网络
      //    身份未被信任。仅对用户可见请求询问一次，同意后本次会话改用
      //    浏览器网络栈并立即重放；首次真实请求失败立即回滚，避免后续请求
      //    全被锁在坏掉的传输状态里。
      if (!isSilent &&
          !triedCompat &&
          compat.canUse(retryOptions) &&
          await compat.enable()) {
        // 撤销"禁走 WebView 适配器"标记：这一行才是让重放真正改走浏览器
        // 网络栈的开关。
        retryOptions.extra.remove(FluxRequestKeys.skipWebViewAdapter);
        final fallback = await _attempt(retryOptions);
        if (fallback case _Succeeded(:final response)) {
          _notify?.call(CfRecoveryNotice.compatEnabled);
          CfChallengeLogger.log(
            '[INTERCEPTOR] Native retry still blocked; '
            'session WebView fallback succeeded',
          );
          return CfRecovered(response);
        }
        compat.rollback();
        CfChallengeLogger.log(
          '[INTERCEPTOR] Session WebView fallback failed: ${fallback.error}',
          level: 'warning',
        );
        return CfRecoveryFailed(fallback.error!);
      }

      // 验证刚通过、Cookie 也带上了，重放仍被拦——定稿值对这个 host 的 Dio
      // 无效。这是确定性环境问题（典型：系统代理只对 WebView 生效，两侧
      // 出口 IP 不一致），再验证多少次都一样：立即冷却，阻断无限循环；
      // 同时把它标记为已死，让下一次验证/新铸值补位。
      round.noteIneffective(host);
      ledger.noteIncumbentChallenged(stillChallenged.carried, host: host);
      CfChallengeLogger.log(
        '[INTERCEPTOR] Verified clearance ineffective for Dio '
        '(retry ${stillChallenged.statusCode}), entering cooldown: $label',
        level: 'warning',
      );
      if (actionPrompt) _notify?.call(CfRecoveryNotice.notEffective);
      return CfRecoveryFailed(stillChallenged.error);
    }
  }

  CfRecoveryResult _roundFailed(
    RequestOptions original,
    CfRoundFailure reason, {
    required String label,
    required String mode,
    required bool actionPrompt,
  }) {
    switch (reason) {
      case CfRoundFailure.cooldown:
        CfChallengeLogger.log(
          '[INTERCEPTOR] Verification skipped by cooldown: $label mode=$mode',
        );
        if (actionPrompt) _notify?.call(CfRecoveryNotice.blockedByChallenge);
        return _fail(original, CfChallengeException(inCooldown: true));
      case CfRoundFailure.noUi:
        CfChallengeLogger.log('[INTERCEPTOR] No context available');
        if (actionPrompt) _notify?.call(CfRecoveryNotice.cannotOpenVerifyPage);
        return _fail(
          original,
          CfChallengeException(cause: '无法获取 context，验证页面未展示'),
        );
      case CfRoundFailure.notLanded:
        CfChallengeLogger.log(
          '[INTERCEPTOR] Verified clearance not landed in jar: $label',
        );
        if (actionPrompt) _notify?.call(CfRecoveryNotice.notEffective);
        return _fail(
          original,
          CfChallengeException(cause: 'cf_clearance cookie 同步失败'),
        );
      case CfRoundFailure.cancelled:
      case CfRoundFailure.timeout:
      case CfRoundFailure.inconclusive:
        // 页面数据请求交给 ErrorView 展示按钮；操作请求给即时提示；静默不打扰
        CfChallengeLogger.log(
          '[INTERCEPTOR] Verification not completed (${reason.name}): '
          '$label mode=$mode',
        );
        if (actionPrompt) _notify?.call(CfRecoveryNotice.verifyIncomplete);
        return _fail(original, CfChallengeException(userCancelled: true));
    }
  }

  static CfRecoveryFailed _fail(
    RequestOptions options,
    CfChallengeException error,
  ) {
    return CfRecoveryFailed(
      DioException(
        requestOptions: options,
        error: error,
        type: DioExceptionType.unknown,
      ),
    );
  }

  /// 重放用的请求选项：复制原请求（headers/extra 各自独立），打上防环标记。
  static RequestOptions _replayOptions(RequestOptions original) {
    final options = original.copyWith();
    // 重放不得再次触发验证（防验证死循环）
    options.extra[FluxRequestKeys.skipCfChallenge] = true;
    // 绕过调度器的验证期冻结与浏览器信任门
    options.extra[FluxRequestKeys.skipCfBlock] = true;
    return options;
  }

  /// 执行一次重放并归类：成功 / 仍被撞（含被 validateStatus 放行的挑战页）/
  /// 其他失败。
  Future<_Attempt> _attempt(RequestOptions options) async {
    try {
      final response = await replay.replay(options);
      if (CfChallengeClassifier.isChallengeResponse(response)) {
        return _StillChallenged(
          DioException.badResponse(
            statusCode: response.statusCode ?? 0,
            requestOptions: options,
            response: response,
          ),
          carriedClearance(options),
        );
      }
      CfChallengeLogger.logInterceptorRetry(
        url: options.uri.toString(),
        success: true,
        statusCode: response.statusCode,
      );
      return _Succeeded(response);
    } on DioException catch (e) {
      if (CfChallengeClassifier.isChallengeResponse(e.response)) {
        return _StillChallenged(e, carriedClearance(options));
      }
      debugPrint(
        '[Dio] Retry failed: status=${e.response?.statusCode}, '
        'type=${e.type}, url=${e.requestOptions.uri}',
      );
      CfChallengeLogger.logInterceptorRetry(
        url: options.uri.toString(),
        success: false,
        error: e.toString(),
      );
      return _Failed(e);
    } catch (e) {
      debugPrint('[Dio] Retry failed (non-Dio): $e');
      CfChallengeLogger.logInterceptorRetry(
        url: options.uri.toString(),
        success: false,
        error: e.toString(),
      );
      return _Failed(
        DioException(
          requestOptions: options,
          error: e,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }
}

/// 一次重放的归类结果。
sealed class _Attempt {
  const _Attempt();

  DioException? get error => switch (this) {
    _Succeeded() => null,
    _Failed(:final error) => error,
    _StillChallenged(:final error) => error,
  };
}

final class _Succeeded extends _Attempt {
  const _Succeeded(this.response);

  final Response<dynamic> response;
}

final class _Failed extends _Attempt {
  const _Failed(this.error);

  @override
  final DioException error;
}

final class _StillChallenged extends _Attempt {
  const _StillChallenged(this.error, this.carried);

  @override
  final DioException error;

  /// 这次重放实际携带的 cf_clearance（= 刚被撞的值）。
  final String? carried;

  int? get statusCode => error.response?.statusCode;
}
