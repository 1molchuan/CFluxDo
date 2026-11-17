import '../utils/time_utils.dart';

/// cdk.linux.do 的数据模型（后端开源：github.com/linux-do/cdk，MIT）。
///
/// 后端是 Go，时间是带时区的 RFC3339，统一经 [TimeUtils.parseUtcTime] 转本地。

int _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _str(Object? v) => v == null ? '' : v.toString();

/// 分发方式（后端 DistributionType）
enum CdkDistributionType {
  /// 一码一用：直接领取
  oneForEach,

  /// 抽奖：按话题楼层抽，领取页只能看
  lottery,

  /// 邀请制
  invite,
  unknown;

  static CdkDistributionType fromValue(Object? v) => switch (_int(v)) {
    0 => CdkDistributionType.oneForEach,
    1 => CdkDistributionType.lottery,
    2 => CdkDistributionType.invite,
    _ => CdkDistributionType.unknown,
  };
}

/// 领取记录（GET /api/v1/projects/received）
class CdkReceivedItem {
  const CdkReceivedItem({
    required this.projectId,
    required this.projectName,
    required this.creatorUsername,
    required this.creatorNickname,
    required this.content,
    required this.receivedAt,
  });

  final String projectId;
  final String projectName;
  final String creatorUsername;
  final String creatorNickname;

  /// 领到的内容（卡密 / 兑换码 / 链接等），不要写进日志
  final String content;
  final DateTime? receivedAt;

  factory CdkReceivedItem.fromJson(Map<String, dynamic> json) =>
      CdkReceivedItem(
        projectId: _str(json['project_id']),
        projectName: _str(json['project_name']),
        creatorUsername: _str(json['project_creator']),
        creatorNickname: _str(json['project_creator_nickname']),
        content: _str(json['content']),
        receivedAt: TimeUtils.parseUtcTime(json['received_at'] as String?),
      );
}

class CdkReceivedPage {
  const CdkReceivedPage({required this.total, required this.items});

  final int total;
  final List<CdkReceivedItem> items;

  factory CdkReceivedPage.fromJson(Map<String, dynamic> json) {
    final results = json['results'];
    return CdkReceivedPage(
      total: _int(json['total']),
      items: results is List
          ? [
              for (final r in results)
                if (r is Map<String, dynamic>) CdkReceivedItem.fromJson(r),
            ]
          : const [],
    );
  }
}

/// 项目详情（GET /api/v1/projects/{id}）
class CdkProject {
  const CdkProject({
    required this.id,
    required this.name,
    required this.description,
    required this.distributionType,
    required this.totalItems,
    required this.availableItems,
    required this.startTime,
    required this.endTime,
    required this.minimumTrustLevel,
    required this.allowSameIp,
    required this.riskLevel,
    required this.price,
    required this.creatorUsername,
    required this.creatorNickname,
    required this.tags,
    required this.isReceived,
    required this.receivedContent,
    required this.isCompleted,
  });

  final String id;
  final String name;

  /// 纯文本（网页端按纯文本换行显示）
  final String description;
  final CdkDistributionType distributionType;
  final int totalItems;
  final int availableItems;
  final DateTime? startTime;
  final DateTime? endTime;
  final int minimumTrustLevel;
  final bool allowSameIp;
  final int riskLevel;

  /// 两位小数的字符串，"0" 或空为免费
  final String price;
  final String creatorUsername;
  final String creatorNickname;
  final List<String> tags;
  final bool isReceived;
  final String receivedContent;
  final bool isCompleted;

  double get priceValue => double.tryParse(price) ?? 0;
  bool get isPaid => priceValue > 0;
  int get receivedCount =>
      (totalItems - availableItems).clamp(0, totalItems < 0 ? 0 : totalItems);

  factory CdkProject.fromJson(Map<String, dynamic> json) {
    final tags = json['tags'];
    return CdkProject(
      id: _str(json['id']),
      name: _str(json['name']),
      description: _str(json['description']),
      distributionType: CdkDistributionType.fromValue(
        json['distribution_type'],
      ),
      totalItems: _int(json['total_items']),
      availableItems: _int(json['available_items_count']),
      startTime: TimeUtils.parseUtcTime(json['start_time'] as String?),
      endTime: TimeUtils.parseUtcTime(json['end_time'] as String?),
      minimumTrustLevel: _int(json['minimum_trust_level']),
      allowSameIp: json['allow_same_ip'] == true,
      riskLevel: _int(json['risk_level']),
      price: _str(json['price']),
      creatorUsername: _str(json['creator_username']),
      creatorNickname: _str(json['creator_nickname']),
      tags: tags is List ? [for (final t in tags) _str(t)] : const [],
      isReceived: json['is_received'] == true,
      receivedContent: _str(json['received_content']),
      isCompleted: json['is_completed'] == true,
    );
  }

  CdkProject copyWithReceived(String content) => CdkProject(
    id: id,
    name: name,
    description: description,
    distributionType: distributionType,
    totalItems: totalItems,
    availableItems: availableItems > 0 ? availableItems - 1 : 0,
    startTime: startTime,
    endTime: endTime,
    minimumTrustLevel: minimumTrustLevel,
    allowSameIp: allowSameIp,
    riskLevel: riskLevel,
    price: price,
    creatorUsername: creatorUsername,
    creatorNickname: creatorNickname,
    tags: tags,
    isReceived: true,
    receivedContent: content,
    isCompleted: isCompleted,
  );
}

/// 领取结果（POST /api/v1/projects/{id}/receive）：免费直接给内容，付费给支付跳转
class CdkReceiveResult {
  const CdkReceiveResult({
    required this.itemContent,
    required this.requirePayment,
    required this.payUrl,
    required this.amount,
  });

  final String itemContent;
  final bool requirePayment;
  final String payUrl;
  final String amount;

  factory CdkReceiveResult.fromJson(Map<String, dynamic> json) =>
      CdkReceiveResult(
        itemContent: _str(json['itemContent'] ?? json['item_content']),
        requirePayment: json['require_payment'] == true,
        payUrl: _str(json['pay_url']),
        amount: _str(json['amount']),
      );
}

/// 当前用户在项目下未过期的待支付订单（GET /api/v1/projects/{id}/pending-payment）
class CdkPendingPayment {
  const CdkPendingPayment({
    required this.hasPending,
    required this.payUrl,
    required this.amount,
  });

  final bool hasPending;
  final String payUrl;
  final String amount;

  factory CdkPendingPayment.fromJson(Map<String, dynamic> json) =>
      CdkPendingPayment(
        hasPending: json['has_pending'] == true,
        payUrl: _str(json['pay_url']),
        amount: _str(json['amount']),
      );
}
