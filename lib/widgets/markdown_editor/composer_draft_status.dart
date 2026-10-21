import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/draft_controller.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/dialog_utils.dart';

enum _DraftConflictChoice { reload, overwrite }

/// 本机和云端都改过同一份草稿时让用户选：返回 true 表示覆盖云端；
/// 选「使用云端版本」会先执行 [onReload] 再返回 false；取消保留本机内容。
Future<bool> confirmComposerDraftOverwrite(
  BuildContext context, {
  Future<void> Function()? onReload,
}) async {
  final choice = await showAppDialog<_DraftConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(context.l10n.composer_draftConflictTitle),
      content: Text(context.l10n.composer_draftConflictBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _DraftConflictChoice.overwrite),
          child: Text(context.l10n.composer_draftOverwrite),
        ),
        if (onReload != null)
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _DraftConflictChoice.reload),
            child: Text(context.l10n.composer_draftUseRemote),
          ),
      ],
    ),
  );
  if (choice == _DraftConflictChoice.reload) await onReload?.call();
  return choice == _DraftConflictChoice.overwrite;
}

String composerDraftStatusLabel(BuildContext context, DraftSaveStatus status) =>
    switch (status) {
      DraftSaveStatus.idle => context.l10n.composer_draftAutoSave,
      DraftSaveStatus.pending => context.l10n.composer_draftPending,
      DraftSaveStatus.saving => context.l10n.composer_draftSaving,
      DraftSaveStatus.saved => context.l10n.composer_draftSaved,
      DraftSaveStatus.local => context.l10n.composer_draftLocal,
      DraftSaveStatus.conflict => context.l10n.composer_draftConflict,
      DraftSaveStatus.error => context.l10n.composer_draftError,
    };

/// 编辑器顶栏的草稿状态。
///
/// 保存中转圈；只存到本机、保存失败、版本冲突常驻一个图标，点它重试或
/// 选版本 —— 这几种状态用户需要知道，也需要能处理。已保存默认不显示，
/// 成功不必一直宣告（[showSaved] 为 true 时显示一枚淡色云朵）。
class ComposerDraftStatusIndicator extends StatelessWidget {
  const ComposerDraftStatusIndicator({
    super.key,
    required this.status,
    required this.onResolve,
    this.showSaved = false,
    this.iconSize = 18,
  });

  final ValueListenable<DraftSaveStatus> status;

  /// 点「存本机 / 失败 / 冲突」图标时调用。
  final VoidCallback? onResolve;
  final bool showSaved;
  final double iconSize;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DraftSaveStatus>(
    valueListenable: status,
    builder: (context, value, _) {
      final theme = Theme.of(context);
      final mj = theme.extension<MojianTokens>();
      final muted = mj?.ink3 ?? theme.colorScheme.outline;
      final alert = mj?.accent ?? theme.colorScheme.error;
      final label = composerDraftStatusLabel(context, value);

      Widget passive(Widget child) => Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(widthFactor: 1, child: child),
          ),
        ),
      );

      Widget actionable(IconData icon, Color color) {
        final action = value == DraftSaveStatus.conflict
            ? context.l10n.composer_draftResolve
            : context.l10n.common_retry;
        return Semantics(
          liveRegion: value != DraftSaveStatus.local,
          child: IconButton(
            key: const ValueKey('composer-draft-status'),
            onPressed: onResolve,
            tooltip: '$label · $action',
            visualDensity: VisualDensity.compact,
            icon: Icon(icon, size: iconSize, color: color),
          ),
        );
      }

      switch (value) {
        case DraftSaveStatus.idle:
        case DraftSaveStatus.pending:
          return const SizedBox.shrink();
        case DraftSaveStatus.saved:
          if (!showSaved) return const SizedBox.shrink();
          return passive(
            Icon(
              Symbols.cloud_done_rounded,
              size: iconSize - 2,
              color: muted,
            ),
          );
        case DraftSaveStatus.saving:
          final size = iconSize - 4;
          return passive(
            SizedBox.square(
              dimension: size,
              child: MediaQuery.disableAnimationsOf(context)
                  ? Icon(Symbols.cloud_upload_rounded, size: size, color: muted)
                  : CircularProgressIndicator(strokeWidth: 1.5, color: muted),
            ),
          );
        case DraftSaveStatus.local:
          return actionable(Symbols.cloud_upload_rounded, muted);
        case DraftSaveStatus.error:
          return actionable(Symbols.cloud_off_rounded, alert);
        case DraftSaveStatus.conflict:
          return actionable(Symbols.sync_problem_rounded, alert);
      }
    },
  );
}
