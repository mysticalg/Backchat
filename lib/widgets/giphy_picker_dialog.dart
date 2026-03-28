import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_message_content.dart';
import '../services/giphy_service.dart';

abstract class GiphyPickerResult {
  const GiphyPickerResult();
}

class GiphyPickedGifResult extends GiphyPickerResult {
  const GiphyPickedGifResult(this.content);

  final ChatMessageContent content;
}

class GiphyPickDeviceGifResult extends GiphyPickerResult {
  const GiphyPickDeviceGifResult();
}

class GiphyPickerDialog extends StatefulWidget {
  const GiphyPickerDialog({
    super.key,
    required this.giphyService,
    required this.languageCode,
  });

  final GiphyService giphyService;
  final String languageCode;

  @override
  State<GiphyPickerDialog> createState() => _GiphyPickerDialogState();
}

class _GiphyPickerDialogState extends State<GiphyPickerDialog> {
  static const int _pageSize = 24;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<GiphyGif> _gifs = <GiphyGif>[];
  String _activeQuery = '';
  int _nextOffset = 0;
  bool _hasMore = false;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!widget.giphyService.isConfigured) {
      setState(() {
        _gifs = <GiphyGif>[];
        _errorMessage =
            'GIPHY search is not configured in this build. You can still send a GIF from your device.';
        _nextOffset = 0;
        _hasMore = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _activeQuery = _searchController.text.trim();
    });
    final int refreshGeneration = ++_refreshGeneration;

    try {
      final GiphyQueryResult result = await _loadPage(
        query: _activeQuery,
        offset: 0,
      );
      if (!mounted || refreshGeneration != _refreshGeneration) {
        return;
      }
      setState(() {
        _gifs = result.gifs;
        _nextOffset = result.nextOffset;
        _hasMore = result.hasMore;
      });
    } on GiphyException catch (e) {
      if (!mounted || refreshGeneration != _refreshGeneration) {
        return;
      }
      setState(() {
        _gifs = <GiphyGif>[];
        _errorMessage = e.message;
        _nextOffset = 0;
        _hasMore = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) {
      return;
    }

    setState(() {
      _isLoadingMore = true;
      _errorMessage = null;
    });

    try {
      final GiphyQueryResult result = await _loadPage(
        query: _activeQuery,
        offset: _nextOffset,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _gifs = <GiphyGif>[..._gifs, ...result.gifs];
        _nextOffset = result.nextOffset;
        _hasMore = result.hasMore;
      });
    } on GiphyException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = e.message;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  Future<GiphyQueryResult> _loadPage({
    required String query,
    required int offset,
  }) {
    if (query.isEmpty) {
      return widget.giphyService.trending(
        limit: _pageSize,
        offset: offset,
        languageCode: widget.languageCode,
      );
    }
    return widget.giphyService.search(
      query,
      limit: _pageSize,
      offset: offset,
      languageCode: widget.languageCode,
    );
  }

  void _onSearchChanged(String _) {
    if (mounted) {
      setState(() {});
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) {
        return;
      }
      unawaited(_refresh());
    });
  }

  void _submitGif(GiphyGif gif) {
    Navigator.of(context).pop(
      GiphyPickedGifResult(
        ChatMessageContent.gif(url: gif.sendUrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Search GIPHY'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    enabled: widget.giphyService.isConfigured,
                    decoration: InputDecoration(
                      hintText: widget.giphyService.isConfigured
                          ? 'Search for a GIF'
                          : 'GIPHY search needs a configured API key',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                unawaited(_refresh());
                              },
                              icon: const Icon(Icons.close),
                            ),
                    ),
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) => unawaited(_refresh()),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop(const GiphyPickDeviceGifResult());
                  },
                  icon: const Icon(Icons.upload_file),
                  label: const Text('From device'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _activeQuery.isEmpty ? 'Trending GIFs' : 'Results for "$_activeQuery"',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Powered by GIPHY',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _buildBody(theme),
            ),
            if (_hasMore) ...<Widget>[
              const SizedBox(height: 10),
              Center(
                child: OutlinedButton(
                  onPressed: _isLoadingMore ? null : _loadMore,
                  child: _isLoadingMore
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Load more'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return _buildMessageState(
        icon: Icons.gif_box_outlined,
        title: _errorMessage!,
        actionLabel: widget.giphyService.isConfigured ? 'Retry' : null,
        onAction: widget.giphyService.isConfigured ? _refresh : null,
      );
    }
    if (_gifs.isEmpty) {
      return _buildMessageState(
        icon: Icons.search_off_outlined,
        title: _activeQuery.isEmpty
            ? 'No trending GIFs are available right now.'
            : 'No GIFs matched that search.',
        actionLabel: widget.giphyService.isConfigured ? 'Refresh' : null,
        onAction: widget.giphyService.isConfigured ? _refresh : null,
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.92,
      ),
      itemCount: _gifs.length,
      itemBuilder: (BuildContext context, int index) {
        final GiphyGif gif = _gifs[index];
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _submitGif(gif),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    child: Image.network(
                      gif.previewUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (
                        BuildContext context,
                        Object error,
                        StackTrace? stackTrace,
                      ) {
                        return Container(
                          color: theme.colorScheme.surfaceContainer,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Text(
                    gif.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessageState({
    required IconData icon,
    required String title,
    String? actionLabel,
    Future<void> Function()? onAction,
  }) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 34,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => unawaited(onAction()),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
