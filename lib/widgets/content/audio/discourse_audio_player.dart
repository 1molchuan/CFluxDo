import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../l10n/s.dart';
import '../../../services/log/log_writer.dart';
import '../../../services/network/gateway_media_source.dart';
import '../../media_player/controls/playback_speed_menu.dart';

/// Discourse 上传音频播放条(替代 legacy 的 fwfh_just_audio 默认条)。
///
/// 用 just_audio 加载 [url],显示 播放/暂停 按钮 + 进度条 + 当前/总时长。
/// 视觉:灰底圆角卡,横排紧凑(高约 56)。
///
/// 由主项目 FluxdoRenderCallbacks.forPost 的 audioBuilder 注入;子包不绑
/// just_audio(平台插件 + 体积)。
class DiscourseAudioPlayer extends StatefulWidget {
  const DiscourseAudioPlayer({super.key, required this.url, this.voice = false});

  /// 已解析好的真实音频 URL(非 upload:// 短链)。
  final String url;

  /// 语音消息形态([wrap=voice] 帖):紧凑胶囊条(整条点按播放 +
  /// 伪波形进度 + 时长),替代通用播放条。
  final bool voice;

  @override
  State<DiscourseAudioPlayer> createState() => _DiscourseAudioPlayerState();
}

class _DiscourseAudioPlayerState extends State<DiscourseAudioPlayer> {
  /// just_audio 默认用自带的本机代理转发自定义请求头，转发时又把 `Host` 写回
  /// 目标地址自己的 host（`_getUrl`）。改写到本机网关的地址于是带着
  /// `Host: 127.0.0.1:端口` 到网关，被回 400「Loopback host is not proxied」——
  /// 加速模式下帖子里的音频（外链、论坛上传、语音消息）全部放不出来（2026-11
  /// 佬友反馈）。安卓上让 ExoPlayer 自己带请求头，与视频播放器同一条路
  final AudioPlayer _player = AudioPlayer(
    useProxyForRequestHeaders: defaultTargetPlatform != TargetPlatform.android,
  );
  bool _ready = false;
  Object? _error;

  /// 当前倍速(just_audio 三后端 —— 官方/media_kit/JustAudioGst 均实现
  /// setSpeed)。换 url 重载后 just_audio 保持 speed,不需要重设。
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final url = widget.url;
    final watch = Stopwatch()..start();
    // 播放器自己联网，不经过 Dart 网关：改写到本机网关才走得了 ECH
    final source = GatewayMediaSource.resolve(url);
    try {
      await _load(source);
      if (mounted && url == widget.url) setState(() => _ready = true);
      return;
    } catch (e) {
      _logFailure(source.viaGateway, watch, e);
      if (!source.viaGateway || !mounted || url != widget.url) {
        if (mounted && url == widget.url) setState(() => _error = e);
        return;
      }
    }
    // 网关那条路不通（外链站点经网关被拒等）：直连再试一次，对齐视频播放器
    try {
      await _load(GatewayMediaSource.direct(url));
      _logRetried(watch);
      if (mounted && url == widget.url) setState(() => _ready = true);
    } catch (e) {
      _logFailure(false, watch, e);
      if (mounted && url == widget.url) setState(() => _error = e);
    }
  }

  Future<void> _load(GatewayMediaSource source) => _player.setUrl(
    source.uri.toString(),
    headers: source.headers.isEmpty ? null : source.headers,
  );

  /// 失败原因只在这里拿得到（ExoPlayer 的 Response code 等），release 包的
  /// debugPrint 是空的，记进应用日志；只记域名和路径
  void _logFailure(bool viaGateway, Stopwatch watch, Object error) {
    final uri = Uri.tryParse(widget.url);
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'media',
      'event': 'audio_load_failed',
      'message': '音频加载失败',
      'host': uri?.host,
      'path': uri?.path,
      'viaGateway': viaGateway,
      'elapsedMs': watch.elapsedMilliseconds,
      'error': error.toString(),
      ...GatewayMediaSource.diagnostics(),
    });
  }

  void _logRetried(Stopwatch watch) {
    final uri = Uri.tryParse(widget.url);
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'media',
      'event': 'audio_direct_retry_ok',
      'message': '音频直连重试成功',
      'host': uri?.host,
      'path': uri?.path,
      'elapsedMs': watch.elapsedMilliseconds,
    });
  }

  @override
  void didUpdateWidget(covariant DiscourseAudioPlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _ready = false;
      _error = null;
      unawaited(_init());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.voice) return _buildVoice(context);
    return _buildRegular(context);
  }

  /// 语音条:胶囊气泡,整条可点(播/停),伪波形显进度(无真波形数据,
  /// 按 url 稳定伪随机生成条高 —— 同一条消息形状恒定)。
  Widget _buildVoice(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
          const SizedBox(width: 6),
          Text(context.l10n.mediaPlayer_voiceLoadFailed,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Material(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: !_ready
                  ? null
                  : () =>
                      _player.playing ? _player.pause() : _player.play(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                child: StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, stateSnap) {
                    final playing = stateSnap.data?.playing ?? false;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 120,
                          height: 28,
                          child: StreamBuilder<Duration>(
                            stream: _player.positionStream,
                            builder: (context, posSnap) {
                              final pos = posSnap.data ?? Duration.zero;
                              final total = _player.duration;
                              final progress = (total == null ||
                                      total.inMilliseconds == 0)
                                  ? 0.0
                                  : (pos.inMilliseconds /
                                          total.inMilliseconds)
                                      .clamp(0.0, 1.0);
                              return CustomPaint(
                                painter: _VoiceBarsPainter(
                                  seed: widget.url.hashCode,
                                  progress: progress,
                                  played: scheme.onPrimaryContainer,
                                  rest: scheme.onPrimaryContainer
                                      .withValues(alpha: 0.35),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        StreamBuilder<Duration>(
                          stream: _player.positionStream,
                          builder: (context, posSnap) {
                            final total = _player.duration;
                            final pos = posSnap.data ?? Duration.zero;
                            // 未播显示总长;播放中显示当前进度
                            final show = (playing || pos > Duration.zero)
                                ? pos
                                : total;
                            return Text(
                              _fmt(show),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRegular(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant, width: 1),
        ),
        child: _error != null
            ? Row(children: [
                Icon(Icons.error_outline_rounded,
                    size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(context.l10n.mediaPlayer_audioLoadFailed,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ])
            : StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(
                    children: [
                      IconButton(
                        icon: Icon(playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                        color: scheme.primary,
                        onPressed: !_ready
                            ? null
                            : () => playing ? _player.pause() : _player.play(),
                      ),
                      Expanded(
                        child: StreamBuilder<Duration>(
                          stream: _player.positionStream,
                          builder: (context, posSnap) {
                            final pos = posSnap.data ?? Duration.zero;
                            final total = _player.duration ?? Duration.zero;
                            final maxMs = total.inMilliseconds == 0
                                ? 1.0
                                : total.inMilliseconds.toDouble();
                            final value = pos.inMilliseconds
                                .clamp(0, maxMs.toInt())
                                .toDouble();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 进度条走全局滑块主题(M3E 开 =
                                // year2023 新样式,媒体控件同款)
                                Slider(
                                  value: value,
                                  max: maxMs,
                                  onChanged: !_ready
                                      ? null
                                      : (v) => _player.seek(
                                          Duration(milliseconds: v.round())),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(_fmt(pos),
                                          style: theme.textTheme.bodySmall),
                                      Text(_fmt(_player.duration),
                                          style: theme.textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      // 倍速按钮:弹共用倍速菜单(Builder 提供锚定 context)
                      Builder(
                        builder: (buttonContext) => TextButton(
                          onPressed: !_ready
                              ? null
                              : () async {
                                  final speed = await showPlaybackSpeedMenu(
                                    buttonContext,
                                    current: _speed,
                                  );
                                  if (speed == null || !mounted) return;
                                  setState(() => _speed = speed);
                                  await _player.setSpeed(speed);
                                },
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 32),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 6),
                            foregroundColor: _speed == 1.0
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                          ),
                          child: Text(
                            formatPlaybackSpeed(_speed),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _speed == 1.0
                                  ? scheme.onSurfaceVariant
                                  : scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// 伪波形竖条(语音条进度指示):[seed] 稳定伪随机条高(LCG),
/// [progress] 之前的条用 [played] 色,之后用 [rest] 色。
class _VoiceBarsPainter extends CustomPainter {
  const _VoiceBarsPainter({
    required this.seed,
    required this.progress,
    required this.played,
    required this.rest,
  });

  final int seed;
  final double progress;
  final Color played;
  final Color rest;

  static const _bars = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / _bars;
    final barW = slot * 0.55;
    var state = seed & 0x7fffffff;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < _bars; i++) {
      // LCG(数值恒定 → 同一 url 形状恒定,重建不闪变)
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      final h = size.height * (0.25 + (state % 1000) / 1000 * 0.75);
      final x = slot * i + slot / 2;
      final done = (i + 0.5) / _bars <= progress;
      paint.color = done ? played : rest;
      paint.strokeWidth = barW;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceBarsPainter old) =>
      old.progress != progress ||
      old.seed != seed ||
      old.played != played ||
      old.rest != rest;
}

