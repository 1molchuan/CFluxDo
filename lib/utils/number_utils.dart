/// 数值工具类 - 统一处理数值格式化
class NumberUtils {
  NumberUtils._();

  /// 格式化数量为简洁形式
  /// 10000+ 显示为 1.0w
  /// 1000+ 显示为 1.0k
  static String formatCount(int count) {
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}w';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
    return count.toString();
  }

  /// 千分位分组（12345 → 12,345），负数保留符号；用在要看精确值的地方
  static String formatThousands(int value) {
    final digits = value.abs().toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return value < 0 ? '-$buf' : buf.toString();
  }

  /// 格式化带趋势符号的整数，正数加 +，负数保留 -。
  static String formatSignedInt(int value) {
    if (value > 0) return '+$value';
    return value.toString();
  }

  /// 格式化持续时间（秒 → 完整可读字符串，用于 Tooltip）
  /// 例：90061 → "1天1小时", 3661 → "1小时1分钟", 120 → "2分钟"
  static String formatDurationLong(int seconds) {
    if (seconds <= 0) return '0分钟';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;

    if (days > 0) {
      if (hours > 0) return '$days天$hours小时';
      return '$days天';
    }
    if (hours > 0) {
      if (minutes > 0) return '$hours小时$minutes分钟';
      return '$hours小时';
    }
    return '$minutes分钟';
  }

  /// 格式化持续时间（秒 → 紧凑字符串，用于卡片展示）
  /// 风格与 formatCount 一致：只保留最大单位 + 后缀
  /// 例：90061 → "25h", 259200 → "3.0d", 120 → "2m"
  static String formatDuration(int seconds) {
    if (seconds <= 0) return '0m';
    final totalMinutes = seconds / 60;
    final totalHours = seconds / 3600;
    final totalDays = seconds / 86400;

    if (totalDays >= 1) {
      return '${totalDays.toStringAsFixed(totalDays >= 10 ? 0 : 1)}d';
    }
    if (totalHours >= 1) {
      return '${totalHours.toStringAsFixed(totalHours >= 10 ? 0 : 1)}h';
    }
    return '${totalMinutes.toInt()}m';
  }
}
