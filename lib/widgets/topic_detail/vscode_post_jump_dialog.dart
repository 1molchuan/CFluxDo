import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../theme/vscode_theme.dart';

/// 编辑器式楼层快速打开，关闭和全局快捷键由调用方的路由管理。
class VscodePostJumpDialog extends StatefulWidget {
  const VscodePostJumpDialog({
    super.key,
    required this.currentPostNumber,
    required this.maxPostNumber,
  }) : assert(maxPostNumber > 0);

  final int currentPostNumber;
  final int maxPostNumber;

  @override
  State<VscodePostJumpDialog> createState() => _VscodePostJumpDialogState();
}

class _VscodePostJumpDialogState extends State<VscodePostJumpDialog> {
  static final _postNumberPattern = RegExp(r'^:?[0-9]+$');
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final initialText = widget.currentPostNumber.toString();
    _controller = TextEditingController.fromValue(
      TextEditingValue(
        text: initialText,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: initialText.length,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  int? get _targetPostNumber {
    final input = _controller.text.trim();
    if (!_postNumberPattern.hasMatch(input)) return null;
    final digits = input.startsWith(':') ? input.substring(1) : input;
    final number = int.tryParse(digits);
    if (number == null || number <= 0) return null;
    return number.clamp(1, widget.maxPostNumber);
  }

  void _selectPostNumber(double value) {
    final text = value.round().clamp(1, widget.maxPostNumber).toString();
    if (_controller.text == text) return;
    setState(() {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  void _submit() {
    if (_submitting || ModalRoute.of(context)?.isCurrent == false) return;
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final target = _targetPostNumber;
    if (target == null) return;
    _submitting = true;
    Navigator.of(context).pop<int>(target);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    final target = _targetPostNumber;
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        MediaQuery.viewInsetsOf(context).bottom + 12,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 520,
          child: Material(
            key: const ValueKey('vscode-post-jump-panel'),
            color: tokens.panel,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: tokens.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter):
                            _submit,
                        const SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _submit,
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.go,
                        maxLines: 1,
                        style: TextStyle(color: tokens.foreground),
                        cursorColor: tokens.accent,
                        decoration: InputDecoration(
                          labelText: l10n.topic_jump,
                          isDense: true,
                          filled: true,
                          fillColor: tokens.background,
                          labelStyle: TextStyle(color: tokens.muted),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.zero,
                            borderSide: BorderSide(color: tokens.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.zero,
                            borderSide: BorderSide(color: tokens.accent),
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      l10n.topic_jumpRange(widget.maxPostNumber),
                      style: TextStyle(color: tokens.muted, fontSize: 12),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter):
                            _submit,
                        const SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _submit,
                      },
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          activeTrackColor: tokens.accent,
                          inactiveTrackColor: tokens.border,
                          thumbColor: tokens.accent,
                          overlayColor: tokens.accent.withValues(alpha: 0.12),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          showValueIndicator: ShowValueIndicator.never,
                        ),
                        child: Slider(
                          key: const ValueKey('vscode-post-jump-slider'),
                          min: 1,
                          max: widget.maxPostNumber.toDouble(),
                          value:
                              (target ??
                                      widget.currentPostNumber.clamp(
                                        1,
                                        widget.maxPostNumber,
                                      ))
                                  .toDouble(),
                          semanticFormatterCallback: (value) =>
                              l10n.topic_jumpTarget(value.round()),
                          onChanged: widget.maxPostNumber > 1
                              ? _selectPostNumber
                              : null,
                          onChangeEnd: widget.maxPostNumber > 1
                              ? (_) => _focusNode.requestFocus()
                              : null,
                        ),
                      ),
                    ),
                  ),
                  if (target != null)
                    TextButton(
                      key: const ValueKey('vscode-post-jump-target'),
                      onPressed: _submit,
                      style: TextButton.styleFrom(
                        foregroundColor: tokens.foreground,
                        backgroundColor: tokens.selection,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        shape: const RoundedRectangleBorder(),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.tag, color: tokens.muted, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(l10n.topic_jumpTarget(target))),
                        ],
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        l10n.topic_jumpInvalid,
                        style: TextStyle(color: tokens.muted),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      l10n.topic_jumpKeyboardHint,
                      style: TextStyle(color: tokens.muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
