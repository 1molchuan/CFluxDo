import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/cert_spki.dart';

// 期望值由 openssl 算出：
// openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
const _ecCa = '''
-----BEGIN CERTIFICATE-----
MIIBxTCCAWugAwIBAgIUWnWzZ2DR76IszNYPbI6aRXmqWvAwCgYIKoZIzj0EAwIw
ODEVMBMGA1UEAwwMRE9IIFByb3h5IENBMRIwEAYDVQQKDAlET0ggUHJveHkxCzAJ
BgNVBAYTAkNOMB4XDTI2MTAxNjAxMzUyNFoXDTM2MTAxMzAxMzUyNFowODEVMBMG
A1UEAwwMRE9IIFByb3h5IENBMRIwEAYDVQQKDAlET0ggUHJveHkxCzAJBgNVBAYT
AkNOMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoZYsX72dEQ+D7Evj3JFOVOwB
zJgfpePKaiohbbjUyl3sEemosHf1LOqpn5LFf05H92z63v3riJzlwgDtYR7Y3KNT
MFEwHQYDVR0OBBYEFDoiK2mSYDoAcy4ND0l1yJeSjDIwMB8GA1UdIwQYMBaAFDoi
K2mSYDoAcy4ND0l1yJeSjDIwMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID
SAAwRQIhAP2+0wT+RkzOblrgMlmwn766wJa1PD+Ahvt2eYc0e2sVAiAF+ISZP/sS
lKQ5LjPrUhwGiZTv6quhN/9cYg5g3ZpJxQ==
-----END CERTIFICATE-----
''';

const _rsaCert = '''
-----BEGIN CERTIFICATE-----
MIIC+TCCAeGgAwIBAgIUQT5JyHibuYFdX9Sy2SRRZc2fZz4wDQYJKoZIhvcNAQEL
BQAwDDEKMAgGA1UEAwwBdDAeFw0yNjEwMTYwMTM1MjRaFw0zNjEwMTMwMTM1MjRa
MAwxCjAIBgNVBAMMAXQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDb
iwW3oB1ko/iuxR85XdC38oDtlmY5Bc/XWp8JzGVIE9iE957MM5PysR4COVjpP6c3
xDGROn3uFXjHuoPaL0K0MjsDb0uYXCkJd99zRxb7K8ig9C2KrXmXh52GW3HUJp7x
Np0G9p31L9EKmbUq3lY9J4PXfLRY+PdO4LgZMD8trfqbqf5Btwa1GrnFhR/TCSVD
Qe50L4BbbCP+DiPiVcFvDXdHsj0WjvptnXJ2Wmv74Xl4An8pScq6Rdqo1BqSDhLe
QxiwaCA3OSLTq5uEJ7hi/5bCDvitX01+wXpaCE6O0KR2C70GNXrnzlN4QQiyDoFF
u15tYHHsqZ3J8UQ/8VolAgMBAAGjUzBRMB0GA1UdDgQWBBRu7493etT7C0d1yZyK
LocAE+zfoDAfBgNVHSMEGDAWgBRu7493etT7C0d1yZyKLocAE+zfoDAPBgNVHRMB
Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBE5JJYivwga0DxAdOo6+6dCcGR
nyaW14r9a51GQFuelaDNOj9GxopUjVsPm4jIa4dJJxzhykn15NOsAcQvvlUtWsUz
Rjmcemis3VX4qW8fGDcyC+PmsSbFMx1ebBUWTJI3DHNuLd90CbGWDZ90yAXQ2Fng
l2kZ59qYFtC722svgu56Zxe4ejB68DA+piS0xeADpauBzyddoQUHbq4WHz2z97fV
Wo/I0z4fKUdMRxNzKEX/mbc/efRg4wgLGc4NUDp4UPwgVHzH1OTVBpifT5KIpw94
DCs85yFiABgHXLhKujAp4ctTe7J1Z7cPH+ATxEFb87DTULtLgG3c54XLcEjm
-----END CERTIFICATE-----
''';

void main() {
  test('EC P-256 自签 CA（与设备 CA 同类）', () {
    expect(spkiSha256Base64(_ecCa), 'QVjFatZeHP+dZnQwTPlGtRFAD2/jWC69DSSTuowBu9w=');
  });

  test('RSA 证书（长度字段两字节）', () {
    expect(spkiSha256Base64(_rsaCert), 'WCsrox0yj9pQ5jX6BX8sxf4SfkNjqqWIGtrQWlFPcOY=');
  });

  test('不是证书时返回 null', () {
    expect(spkiSha256Base64('not a pem'), isNull);
    expect(spkiSha256Base64('-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----'), isNull);
  });
}
