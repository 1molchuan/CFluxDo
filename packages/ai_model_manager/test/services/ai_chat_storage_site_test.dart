import 'package:ai_model_manager/models/ai_chat_message.dart';
import 'package:ai_model_manager/services/ai_chat_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('相同话题和会话 ID 在不同站点独立保存，清理一站不删除另一站', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final original = AiChatStorageService(prefs);
    final other = AiChatStorageService(prefs, sessionNamespace: 'site:idcflare:');
    AiChatMessage message(String content) => AiChatMessage(
      id: 'message',
      role: ChatRole.user,
      content: content,
      createdAt: DateTime.utc(2026, 10, 23),
    );

    await original.saveSessionMessages(42, 'session', [message('原站的问题')],
        topicTitle: '原站话题');
    await other.saveSessionMessages(42, 'session', [message('新站的问题')],
        topicTitle: '新站话题');

    expect(original.loadSessionMessages('session').single.content, '原站的问题');
    expect(other.loadSessionMessages('session').single.content, '新站的问题');
    expect(original.getAllTopicsWithSessions().single.topicTitle, '原站话题');
    expect(other.getAllTopicsWithSessions().single.topicTitle, '新站话题');

    await other.deleteAllSessions();
    expect(other.getTopicSessions(42), isEmpty);
    expect(other.loadSessionMessages('session'), isEmpty);
    expect(original.getTopicSessions(42).single.id, 'session');
    expect(original.loadSessionMessages('session').single.content, '原站的问题');
  });
}
