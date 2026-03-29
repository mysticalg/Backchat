final RegExp messageUrlPattern = RegExp(
  r'(?:(?:https?://)|(?:www\.)|(?:[a-z0-9-]+\.)+[a-z]{2,})[^\s<>()]*',
  caseSensitive: false,
);

Uri? normalizeHttpUrl(String rawValue) {
  final String trimmed = rawValue.trim().replaceAll(RegExp(r'[.,!?;:]+$'), '');
  if (trimmed.isEmpty) {
    return null;
  }
  final String candidate =
      trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final Uri? uri = Uri.tryParse(candidate);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.trim().isEmpty) {
    return null;
  }
  return uri;
}
