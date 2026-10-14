import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/cf_select_notice.dart';

void main() {
  group('CfSelectNotice.majorMinor', () {
    test('去掉补丁号、预发布标识和构建号', () {
      expect(CfSelectNotice.majorMinor('1.1.0-beta.3+2026'), '1.1');
      expect(CfSelectNotice.majorMinor('1.1.0'), '1.1');
      expect(CfSelectNotice.majorMinor('1.1.7+2026101499'), '1.1');
      expect(CfSelectNotice.majorMinor('2.0.0-rc.1'), '2.0');
    });

    test('段数不够或为空时尽量给出可比较的值', () {
      expect(CfSelectNotice.majorMinor('2'), '2');
      expect(CfSelectNotice.majorMinor('1.2'), '1.2');
      expect(CfSelectNotice.majorMinor(''), '');
      expect(CfSelectNotice.majorMinor(' 1.3.0 '), '1.3');
    });
  });

  group('CfSelectNotice.shouldShow', () {
    test('没记录过要弹', () {
      expect(
        CfSelectNotice.shouldShow(currentVersion: '1.1.0', storedVersion: null),
        isTrue,
      );
      expect(
        CfSelectNotice.shouldShow(currentVersion: '1.1.0', storedVersion: ''),
        isTrue,
      );
    });

    test('同一个 major.minor 内只弹一次（补丁版 / 预发布都算同一批）', () {
      expect(
        CfSelectNotice.shouldShow(
          currentVersion: '1.1.3',
          storedVersion: '1.1.0',
        ),
        isFalse,
      );
      expect(
        CfSelectNotice.shouldShow(
          currentVersion: '1.1.0',
          storedVersion: '1.1.0-beta.2+2026',
        ),
        isFalse,
      );
      // 记录的是 majorMinor 形式也能比
      expect(
        CfSelectNotice.shouldShow(
          currentVersion: '1.1.5',
          storedVersion: '1.1',
        ),
        isFalse,
      );
    });

    test('升到新的 minor 或 major 再弹', () {
      expect(
        CfSelectNotice.shouldShow(
          currentVersion: '1.2.0',
          storedVersion: '1.1.9',
        ),
        isTrue,
      );
      expect(
        CfSelectNotice.shouldShow(
          currentVersion: '2.0.0',
          storedVersion: '1.1.0',
        ),
        isTrue,
      );
    });
  });
}
