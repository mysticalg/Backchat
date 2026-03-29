import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (!_supportsInlineWebView) {
      return _fallback(theme, 'Inline embeds are not available on this platform.');
    }
    if (_errorMessage != null) {
      return _fallback(theme, _errorMessage!);
    }
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
                  initialData: InAppWebViewInitialData(
                    data: const SocialEmbedService().buildEmbedHtml(
                      widget.descriptor,
                    ),
                    mimeType: 'text/html',
                    encoding: 'utf-8',
                    baseUrl: WebUri.uri(widget.descriptor.sourceUrl),
                  ),
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
