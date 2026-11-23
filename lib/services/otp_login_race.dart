import 'dart:async';

import 'package:dio/dio.dart';

import 'user_api_key_service.dart';

/// 拿口令换会话的最终结果。
enum OtpLoginOutcome {
  /// 原生这条路换到了会话（登录收口还没做，由调用方接着做）。
  nativeSucceeded,

  /// 内置网页那条路完成了登录（收口已经由登录页做完）。
  webSucceeded,

  /// 服务端不认这枚口令（过期 / 已用过）：留着也没用。
  rejected,

  /// 两条路都没成，口令还在有效期内，可以稍后接着来。
  unfinished,
}

/// 内置网页那条路向竞速报告的事（登录页拿着它）。
abstract interface class OtpWebLeg {
  /// 网页里已经登录上了，准备把会话搬回原生。返回 false 表示原生已经先成了：
  /// 网页这边什么都不要写，直接收场。
  bool claim();

  /// 确认页明确说口令无效。
  void reportRejected();

  /// 页面停在需要人来点的地方（人机验证等）。
  void reportNeedsUser();
}

/// 竞速要界面配合做的事。
abstract interface class OtpWebLegHost {
  /// 打开内置网页那条路。返回的 Future 在网页关闭时完成：true = 网页完成了
  /// 登录；其他值 = 没成（用户退出、口令被拒、被 [close] 撤掉）。
  Future<bool?> open(OtpWebLeg leg);

  /// 把网页撤掉（原生先成了）。
  void close();

  /// 让用户看见网页（撤掉「正在完成登录」的遮罩）。
  void reveal();

  /// 重新盖上遮罩（网页已经关了，还在等原生的结果）。
  void conceal();
}

/// 拿一次性口令换会话：原生和内置网页错峰竞速，谁先换到用谁。
///
/// 原生通常一两秒就能换完，网页那条路要十几秒，所以不同时起跑：
/// - 原生先跑；它要发两个请求，每一步在 [stagger] 内有进展就接着等，换到了
///   就按结果办，网页根本不启动；
/// - 原生有一步 [stagger] 内没动静（连接卡住）：网页在遮罩后面悄悄起跑，
///   之后谁先换到用谁——原生先成就把网页撤掉，网页先成就取消原生的请求；
/// - 原生很快失败但口令还在（被人机验证拦下、连不上）：立刻改走网页，
///   并且让用户看见它；
/// - 网页停在要人点的地方、或悄悄跑了 [revealAfter] 还没结果：撤掉遮罩。
///
/// 口令是一次性的，正常只有一边换得成：另一边会被服务端告知口令无效。
/// 所以「原生说口令无效」在网页还在跑的时候不算数（多半是网页刚把它用掉），
/// 要等网页那边的结果；反过来也一样。
class OtpLoginRace implements OtpWebLeg {
  OtpLoginRace({
    required this.redeemNative,
    required this.host,
    bool Function()? holdWeb,
    this.stagger = const Duration(seconds: 2),
    this.revealAfter = const Duration(seconds: 12),
    this.holdPoll = const Duration(milliseconds: 500),
    void Function(String message)? log,
  }) : _holdWeb = holdWeb ?? _never,
       _log = log ?? _silent;

  /// 原生多久没有进展，网页才悄悄起跑。
  final Duration stagger;

  /// 网页悄悄跑了这么久还没结果，就让用户看见它。
  final Duration revealAfter;

  /// [holdWeb] 为 true 期间多久再问一次。
  final Duration holdPoll;

  /// 原生那条路：拿口令换会话。取消令牌在网页先成时被取消；每走完一步
  /// （取到 CSRF）调一次 `onProgress`，说明连接是通的、只是还没换完。
  final Future<OtpRedeemResult> Function(
    CancelToken cancelToken,
    void Function() onProgress,
  )
  redeemNative;

  /// 内置网页那条路的界面。
  final OtpWebLegHost host;

  /// 现在不要启动网页：原生那边正开着人机验证页让用户点，再起一个网页只会
  /// 添乱。验证结束后重新给原生一个 [stagger]。
  final bool Function() _holdWeb;
  final void Function(String message) _log;

  static bool _never() => false;
  static void _silent(String _) {}

  final Completer<OtpLoginOutcome> _done = Completer<OtpLoginOutcome>();
  final CancelToken _nativeCancel = CancelToken();
  Timer? _staggerTimer;
  Timer? _revealTimer;
  bool _started = false;
  bool _held = false;

  OtpRedeemResult? _nativeResult;
  bool _webStarted = false;
  bool _webOpen = false;
  bool _webClaimed = false;
  bool _webRejected = false;

  Future<OtpLoginOutcome> run() {
    if (_started) return _done.future;
    _started = true;
    _staggerTimer = Timer(stagger, _onStagger);
    unawaited(_runNative());
    return _done.future;
  }

  Future<void> _runNative() async {
    OtpRedeemResult result;
    try {
      result = await redeemNative(_nativeCancel, _onNativeProgress);
    } catch (_) {
      result = const OtpRedeemResult.failed(OtpRedeemFailure.network);
    }
    _onNativeResult(result);
  }

  /// 原生走完了一步：连接没卡住，重新给它一个错峰间隔。
  void _onNativeProgress() {
    if (_done.isCompleted || _nativeResult != null || _webStarted) return;
    _staggerTimer?.cancel();
    _staggerTimer = Timer(stagger, _onStagger);
  }

  void _onNativeResult(OtpRedeemResult result) {
    _nativeResult = result;
    _staggerTimer?.cancel();
    // 网页已经认领：原生这边的结果不再算数（请求多半是被我们取消的）
    if (_done.isCompleted || _webClaimed) return;

    if (result.ok) {
      _log('原生换到了会话${_webOpen ? '，撤掉网页' : ''}');
      if (_webOpen) host.close();
      _finish(OtpLoginOutcome.nativeSucceeded);
      return;
    }

    if (!_webStarted) {
      if (!result.retryable) {
        _finish(OtpLoginOutcome.rejected);
        return;
      }
      _log('原生没换成（${result.failure?.name}），改走内置网页');
      _startWeb(quiet: false);
      return;
    }

    if (!_webOpen) {
      // 网页那条路已经收场，原生也没成
      _finish(_closedWithoutSession);
      return;
    }

    if (result.retryable) {
      // 只剩网页这一条路：让用户看见它
      _log('原生没换成（${result.failure?.name}），等内置网页');
      host.reveal();
    }
    // 口令被拒：多半是网页刚把它用掉，等网页那边的结果
  }

  void _onStagger() {
    if (_done.isCompleted || _nativeResult != null || _webStarted) return;
    if (_holdWeb()) {
      _held = true;
      _staggerTimer = Timer(holdPoll, _onStagger);
      return;
    }
    if (_held) {
      // 验证刚结束，原生马上会重放请求：再等它一个错峰间隔
      _held = false;
      _staggerTimer = Timer(stagger, _onStagger);
      return;
    }
    _log('原生 ${stagger.inMilliseconds} ms 没有进展，内置网页在后台起跑');
    _startWeb(quiet: true);
  }

  void _startWeb({required bool quiet}) {
    _webStarted = true;
    _webOpen = true;
    if (quiet) {
      _revealTimer = Timer(revealAfter, () {
        if (_webOpen && !_done.isCompleted) host.reveal();
      });
    } else {
      host.reveal();
    }
    unawaited(
      host
          .open(this)
          .then<void>(_onWebClosed, onError: (Object _) => _onWebClosed(null)),
    );
  }

  @override
  bool claim() {
    if (_done.isCompleted) return false;
    if (!_webClaimed) {
      _webClaimed = true;
      if (_nativeResult == null) {
        _log('内置网页先登录上了，取消原生的请求');
        _nativeCancel.cancel('内置网页已经换到会话');
      } else {
        _log('内置网页登录上了');
      }
    }
    return true;
  }

  @override
  void reportRejected() => _webRejected = true;

  @override
  void reportNeedsUser() {
    if (_webOpen && !_done.isCompleted) host.reveal();
  }

  void _onWebClosed(bool? succeeded) {
    _webOpen = false;
    _revealTimer?.cancel();
    if (_done.isCompleted) return;

    if (succeeded == true) {
      if (!_webClaimed && _nativeResult == null) {
        _nativeCancel.cancel('内置网页已经完成登录');
      }
      _webClaimed = true;
      _finish(OtpLoginOutcome.webSucceeded);
      return;
    }
    if (_webClaimed) {
      // 认领之后没收口成（用户中途退出等）：口令已经被网页用掉了
      _finish(OtpLoginOutcome.unfinished);
      return;
    }
    if (_nativeResult == null) {
      // 网页收场了，原生还没回来：盖回遮罩接着等
      _log('内置网页已关闭（${_webRejected ? '口令被拒' : '未完成'}），等原生的结果');
      host.conceal();
      return;
    }
    _finish(_closedWithoutSession);
  }

  /// 两条路都收场了、谁也没换到会话时的结论。
  OtpLoginOutcome get _closedWithoutSession {
    final native = _nativeResult;
    final nativeRejected = native != null && !native.retryable;
    return _webRejected || nativeRejected
        ? OtpLoginOutcome.rejected
        : OtpLoginOutcome.unfinished;
  }

  void _finish(OtpLoginOutcome outcome) {
    if (_done.isCompleted) return;
    _staggerTimer?.cancel();
    _revealTimer?.cancel();
    _log('结果：${outcome.name}');
    _done.complete(outcome);
  }
}
