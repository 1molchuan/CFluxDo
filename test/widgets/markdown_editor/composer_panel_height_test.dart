import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_panel_height.dart';

void main() {
  group('resolveComposerPanelHeight', () {
    test('正常软键盘高度直接作为面板高度', () {
      expect(
        resolveComposerPanelHeight(
          keyboardHeight: 320,
          fallbackHeight: 280,
          safeBottom: 24,
        ),
        320,
      );
    });

    test('浮动/外接键盘回报的过小高度回退到默认面板高度', () {
      for (final small in [1.0, 48.0, 120.0, 199.9]) {
        expect(
          resolveComposerPanelHeight(
            keyboardHeight: small,
            fallbackHeight: 280,
            safeBottom: 24,
          ),
          280,
          reason: 'keyboardHeight=$small',
        );
      }
    });

    test('从未拿到键盘高度时用默认面板高度', () {
      expect(
        resolveComposerPanelHeight(
          keyboardHeight: 0,
          fallbackHeight: 280,
          safeBottom: 24,
        ),
        280,
      );
    });

    test('结果不低于底部安全区', () {
      expect(
        resolveComposerPanelHeight(
          keyboardHeight: 0,
          fallbackHeight: 10,
          safeBottom: 34,
        ),
        34,
      );
    });

    test('200 是停靠软键盘的下限', () {
      expect(isComposerDockedKeyboardHeight(200), isTrue);
      expect(isComposerDockedKeyboardHeight(199.9), isFalse);
    });
  });
}
