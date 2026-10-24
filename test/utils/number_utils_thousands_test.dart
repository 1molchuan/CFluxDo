import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/number_utils.dart';

void main() {
  test('formatThousands 千分位分组，负数保留符号', () {
    expect(NumberUtils.formatThousands(0), '0');
    expect(NumberUtils.formatThousands(999), '999');
    expect(NumberUtils.formatThousands(1000), '1,000');
    expect(NumberUtils.formatThousands(9483), '9,483');
    expect(NumberUtils.formatThousands(795536), '795,536');
    expect(NumberUtils.formatThousands(1234567), '1,234,567');
    expect(NumberUtils.formatThousands(-1512), '-1,512');
  });
}
