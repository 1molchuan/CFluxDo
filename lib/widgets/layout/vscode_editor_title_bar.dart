import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../theme/vscode_theme.dart';

/// 仅表示当前阅读文档，不建立独立的标签页状态或导航栈。
class VscodeEditorTitleBar extends StatelessWidget
    implements PreferredSizeWidget {
  const VscodeEditorTitleBar({
    super.key,
    required this.title,
    required this.actions,
    this.onClose,
  });

  final String title;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Size get preferredSize => const Size.fromHeight(36);

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    return Theme(
      data: VscodeTheme.toolbarTheme(Theme.of(context)),
      child: Material(
        color: tokens.border,
        child: SafeArea(
          bottom: false,
          child: Container(
            height: preferredSize.height,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 380),
                      height: double.infinity,
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      decoration: BoxDecoration(
                        color: tokens.background,
                        border: Border(
                          top: BorderSide(color: tokens.accent),
                          right: BorderSide(color: tokens.border),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 15,
                            color: tokens.accent,
                          ),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Tooltip(
                              message: title,
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: tokens.foreground,
                                      fontSize: 12,
                                    ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (onClose != null)
                            IconButton(
                              tooltip: context.l10n.common_close,
                              onPressed: onClose,
                              iconSize: 16,
                              style: IconButton.styleFrom(
                                shape: const RoundedRectangleBorder(),
                              ),
                              icon: const Icon(Icons.close),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconTheme(
                  data: IconThemeData(size: 16, color: tokens.muted),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
