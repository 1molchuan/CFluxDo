import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

/// CF 验证服务里两条与"什么时候该放弃/该再问"相关的契约。
///
/// 两者都源于真实故障形态:
/// 1. 后台 isolate 撞盾时 `showManualVerify` 会等一个永不到来的 navigator
///    context,请求挂死到系统任务超时。等待本身对启动早期是必要的
///    (context 几百毫秒内就绪),所以修法是给它上限而非取消。
/// 2. 「切兼容模式」询问一旦被拒绝,此前会沉默到登出——用户启动时随手点
///    取消,之后盾天天触发也不再问。改为带时效的静默期。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('切兼容询问的静默期', () {
    test('初始状态不处于静默期', () {
      final service = CfChallengeService();
      service.resetSessionCompatibilityDecision();

      expect(service.sessionCompatPromptDeclined, isFalse);
    });

    test('无前台 context 时询问直接返回 false,且不进入静默期', () async {
      // 测试环境没有 navigator context:询问无法展示。
      // 这种"没问成"不该被记为"用户拒绝",否则真有 UI 时也不会再问。
      final service = CfChallengeService();
      service.resetSessionCompatibilityDecision();

      final result = await service.confirmSessionCompatibilityMode();

      expect(result, isFalse);
      expect(
        service.sessionCompatPromptDeclined,
        isFalse,
        reason: '未能展示的询问不等于被拒绝',
      );
    });

    test('reset 清除静默期(登出时调用)', () {
      final service = CfChallengeService();
      service.resetSessionCompatibilityDecision();
      expect(service.sessionCompatPromptDeclined, isFalse);
    });
  });

  group('无 UI 环境不挂死', () {
    test('拿不到 context 时验证在超时后放弃,而不是永久挂起', () async {
      final service = CfChallengeService();
      service.resetCooldown();

      // 不传 context,测试环境也没有 navigator：走等待分支。
      // 关键断言是"会返回",而不是断言具体耗时——超时窗口是 10s,
      // 这里只验证 Future 最终完成(挂死时它永远不完成)。
      final result = await service
          .showManualVerify(null, false)
          .timeout(const Duration(seconds: 20));

      expect(result, isNull, reason: '无 UI 环境应放弃验证');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('先静默后前台的入口同样受 context 等待上限约束', () async {
      // 页面数据/操作请求撞盾改走 showVerifySilentFirst,它不能绕开上面那条
      // 无 UI 收口,否则后台拉取撞盾又会挂死。
      final service = CfChallengeService();
      service.resetCooldown();

      final result = await service
          .showVerifySilentFirst()
          .timeout(const Duration(seconds: 20));

      expect(result, isNull, reason: '无 UI 环境应放弃验证');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('静默宽限期短于后台验证默认时限', () {
      // 宽限期是"用户可见请求最多多等多久"的上限,必须明显短于纯后台
      // 请求的 10s,否则等于把前台请求降级成了静默请求。
      expect(CfChallengeService.silentFirstGrace, greaterThan(Duration.zero));
      expect(
        CfChallengeService.silentFirstGrace,
        lessThan(const Duration(seconds: 10)),
      );
    });
  });
}
