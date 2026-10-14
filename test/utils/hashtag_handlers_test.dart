import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/font_awesome_helper.dart';
import 'package:fluxdo/utils/hashtag_handlers.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show hashtagIconResolver;

/// hashtag 药丸宿主图标解析的回归:发帖器预览(客户端 cook)给的标签 href
/// 是未编码的中文原文,解析器必须能处理而不是抛异常 —— 抛了子包会按
/// 兜底图标渲染,但原因在这里,得从源头保证拿得到标签自己的图标。
void main() {
  late BuildContext ctx;

  Future<void> pumpHost(WidgetTester tester) async {
    installHashtagHandlers();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('标签 href 未编码中文:拿到 TagIconList 里配的图标', (tester) async {
    await pumpHost(tester);
    final resolver = hashtagIconResolver!;
    final expected = FontAwesomeHelper.getIcon('file-code')!.data;

    // 客户端 cook 预览写法(原文)
    expect(resolver(ctx, 'square-full', '/tag/软件开发'), expected);
    // 服务端 cooked 写法(百分号编码)
    expect(
      resolver(ctx, 'square-full', '/tag/%E8%BD%AF%E4%BB%B6%E5%BC%80%E5%8F%91'),
      expected,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没配图标的中文标签回 null 交给子包兜底,不抛', (tester) async {
    await pumpHost(tester);
    final resolver = hashtagIconResolver!;

    expect(resolver(ctx, 'square-full', '/tag/开源推广'), isNull);
    expect(tester.takeException(), isNull);
  });
}
