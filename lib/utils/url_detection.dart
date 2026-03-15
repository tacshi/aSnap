String? extractFirstUrl(String text) {
  final List<String> candidates = [];

  String? firstMatch(RegExp pattern, {bool rejectIfPrecededByAt = false}) {
    for (final match in pattern.allMatches(text)) {
      final value = match.group(0);
      if (value == null || value.isEmpty) continue;
      if (rejectIfPrecededByAt) {
        final start = match.start;
        if (start > 0 && text[start - 1] == '@') {
          continue;
        }
      }
      return value;
    }
    return null;
  }

  final schemeMatch = firstMatch(
    RegExp(r'\bhttps?:\/\/[^\s<>()\[\]{}]+', caseSensitive: false),
  );
  if (schemeMatch != null) {
    candidates.add(schemeMatch);
  }

  if (candidates.isEmpty) {
    final wwwMatch = firstMatch(
      RegExp(r'\bwww\.[^\s<>()\[\]{}]+', caseSensitive: false),
    );
    if (wwwMatch != null) {
      candidates.add(wwwMatch);
    }
  }

  if (candidates.isEmpty) {
    final domainMatch = firstMatch(
      RegExp(
        r'\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?:\/[^\s<>()\[\]{}]*)?',
        caseSensitive: false,
      ),
      rejectIfPrecededByAt: true,
    );
    if (domainMatch != null) {
      candidates.add(domainMatch);
    }
  }

  if (candidates.isEmpty) return null;

  var candidate = candidates.first.trim();
  candidate = candidate.replaceAll(RegExp(r"^['\(\[\{<]+"), '');
  candidate = candidate.replaceAll(RegExp(r"[\)\]\}>.,;!?]+$"), '');

  if (candidate.contains('@')) return null;
  if (!candidate.contains('://')) {
    candidate = 'https://$candidate';
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null) return null;
  if (uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.toString();
}
