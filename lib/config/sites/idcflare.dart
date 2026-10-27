import '../site_customization.dart';

/// IDCFlare 不套用 LINUX DO 专属发帖插件及用户样式。
const idcflareCustomization = SiteCustomization(
  linkSecurityConfig: LinkSecurityConfig(
    internalDomains: ['idcflare.com'],
    trustedDomains: ['*.idcflare.com', '*.linux.do'],
  ),
);
