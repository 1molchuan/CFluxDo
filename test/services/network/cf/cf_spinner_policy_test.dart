import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_spinner_policy.dart';

/// 验证页「转圈时别露给用户」的判定。
void main() {
  test('挑战出来了但还没要人工操作 = 转圈；要了或渲染进程没了都不算', () {
    expect(
      CfSpinnerPolicy.spinning(
        hasSeenChallenge: true,
        interactiveSignaled: false,
        renderGone: false,
      ),
      isTrue,
    );
    expect(
      CfSpinnerPolicy.spinning(
        hasSeenChallenge: true,
        interactiveSignaled: true,
        renderGone: false,
      ),
      isFalse,
    );
    expect(
      CfSpinnerPolicy.spinning(
        hasSeenChallenge: false,
        interactiveSignaled: false,
        renderGone: false,
      ),
      isFalse,
      reason: '页面还没出挑战（加载中 / 网络问题）不算转圈，不延长后台',
    );
    expect(
      CfSpinnerPolicy.spinning(
        hasSeenChallenge: true,
        interactiveSignaled: false,
        renderGone: true,
      ),
      isFalse,
    );
  });

  test('前台：勾选框出来前先盖着；兜底到点（force）照样露', () {
    expect(
      CfSpinnerPolicy.deferReveal(
        isBackground: false,
        interactiveSignaled: false,
        force: false,
      ),
      isTrue,
    );
    expect(
      CfSpinnerPolicy.deferReveal(
        isBackground: false,
        interactiveSignaled: true,
        force: false,
      ),
      isFalse,
    );
    expect(
      CfSpinnerPolicy.deferReveal(
        isBackground: false,
        interactiveSignaled: false,
        force: true,
      ),
      isFalse,
    );
    expect(
      CfSpinnerPolicy.deferReveal(
        isBackground: true,
        interactiveSignaled: false,
        force: false,
      ),
      isFalse,
      reason: '后台本来就看不见，不用推迟',
    );
  });

  test('后台预算：转圈时至少 20 s，原本更长的（预授权辅助）不缩短', () {
    expect(
      CfSpinnerPolicy.backgroundBudgetSeconds(baseSeconds: 6, spinning: true),
      20,
    );
    expect(
      CfSpinnerPolicy.backgroundBudgetSeconds(baseSeconds: 6, spinning: false),
      6,
    );
    expect(
      CfSpinnerPolicy.backgroundBudgetSeconds(baseSeconds: 24, spinning: true),
      24,
    );
  });

  test('6 s 宽限期到点：转圈就不弹前台；用户主动要的前台不受影响', () {
    expect(
      CfSpinnerPolicy.holdGracePromotion(
        afterGrace: true,
        isBackground: true,
        spinning: true,
      ),
      isTrue,
    );
    expect(
      CfSpinnerPolicy.holdGracePromotion(
        afterGrace: false,
        isBackground: true,
        spinning: true,
      ),
      isFalse,
      reason: '勾选框出来 / 用户点了验证入口 / 预算到点，都直接弹',
    );
    expect(
      CfSpinnerPolicy.holdGracePromotion(
        afterGrace: true,
        isBackground: true,
        spinning: false,
      ),
      isFalse,
    );
  });
}
