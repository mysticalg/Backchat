import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/social_embed_service.dart';

class SocialEmbedCard extends StatefulWidget {
  const SocialEmbedCard({
    super.key,
    required this.descriptor,
  });

  final SocialEmbedDescriptor descriptor;

  @override
  State<SocialEmbedCard> createState() => _SocialEmbedCardState();
}

class _SocialEmbedCardState extends State<SocialEmbedCard> {
  bool _isLoading = true;
  String? _errorMessage;
  String? _appRefererUrl;

  bool get _requiresYouTubeReferer =>
      !kIsWeb && widget.descriptor.provider == 'youtube';

  bool get _supportsInlineWebView {
    if (kIsWeb) {
      return true;
    }
    if (Platform.isLinux) {
      return false;
    }
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  @override
  void initState() {
    super.initState();
    _primeYouTubeReferer();
  }

  @override
  void didUpdateWidget(covariant SocialEmbedCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.descriptor.provider != widget.descriptor.provider ||
        oldWidget.descriptor.embedUrl != widget.descriptor.embedUrl) {
      _errorMessage = null;
      _isLoading = true;
      _appRefererUrl = null;
      _primeYouTubeReferer();
    }
  }

  Future<void> _primeYouTubeReferer() async {
    if (!_requiresYouTubeReferer) {
      return;
    }
    final String resolvedReferer = await _resolveAppRefererUrl();
    if (!mounted) {
      return;
    }
    setState(() {
      _appRefererUrl = resolvedReferer;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (!_supportsInlineWebView) {
      return _fallback(
          theme, 'Inline embeds are not available on this platform.');
    }
    if (_errorMessage != null) {
      return _fallback(theme, _errorMessage!);
    }
    if (_requiresYouTubeReferer && _appRefererUrl == null) {
      return _loadingShell();
    }
    final URLRequest? initialUrlRequest = _buildInitialUrlRequest();
    final InAppWebViewInitialData? initialData = initialUrlRequest == null
        ? InAppWebViewInitialData(
            data: const SocialEmbedService().buildEmbedHtml(
              widget.descriptor,
            ),
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: WebUri.uri(widget.descriptor.sourceUrl),
          )
        : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: widget.descriptor.aspectRatio,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    iframeAllow:
                        'autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture',
                    iframeAllowFullscreen: true,
                    transparentBackground: true,
                    supportZoom: false,
                  ),
                  initialUrlRequest: initialUrlRequest,
                  initialData: initialData,
                  onLoadStop: (_, __) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _isLoading = false;
                    });
                  },
                  onReceivedError: (_, __, error) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _isLoading = false;
                      _errorMessage = error.description;
                    });
                  },
                ),
              ),
              if (_isLoading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  URLRequest? _buildInitialUrlRequest() {
    if (!_requiresYouTubeReferer) {
      return null;
    }
    final String referer = _appRefererUrl!;
    final Uri embedUri = Uri.parse(widget.descriptor.embedUrl);
    final Uri requestUri = embedUri.replace(
      queryParameters: <String, String>{
        ...embedUri.queryParameters,
        'origin': referer,
        'widget_referrer': referer,
      },
    );
    return URLRequest(
      url: WebUri.uri(requestUri),
      headers: <String, String>{'Referer': referer},
    );
  }

  Future<String> _resolveAppRefererUrl() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final String rawPackageId = packageInfo.packageName.trim().toLowerCase();
      final String packageId =
          rawPackageId.contains('.') ? rawPackageId : 'com.mysticalg.backchat';
      if (packageId.isNotEmpty) {
        return Uri(
          scheme: 'https',
          host: packageId.replaceAll(RegExp(r'[^a-z0-9.-]'), '-'),
        ).toString();
      }
    } catch (_) {
      // Fall back to a stable app-like identifier when package metadata is unavailable.
    }
    return 'https://com.mysticalg.backchat';
  }

  Widget _loadingShell() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: widget.descriptor.aspectRatio,
          child: const ColoredBox(
            color: Colors.black,
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(ThemeData theme, String message) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
