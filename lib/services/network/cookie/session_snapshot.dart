class SessionSnapshot {
  const SessionSnapshot({
    this.tToken,
    this.forumSession,
  });

  final String? tToken;
  final String? forumSession;

  bool get hasSession => tToken != null && tToken!.isNotEmpty;
  bool get hasForumSession => forumSession != null && forumSession!.isNotEmpty;
  String? get fingerprint => hasSession ? tToken : null;

  static SessionSnapshot fromValues({
    String? tToken,
    String? forumSession,
  }) {
    return SessionSnapshot(
      tToken: _normalize(tToken),
      forumSession: _normalize(forumSession),
    );
  }

  static String? _normalize(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}
