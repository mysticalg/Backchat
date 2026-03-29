import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class InlineAudioPlayer extends StatefulWidget {
  const InlineAudioPlayer({
    super.key,
    required this.url,
    this.title = '',
  });

  final String url;
  final String title;

  @override
  State<InlineAudioPlayer> createState() => _InlineAudioPlayerState();
}

class _InlineAudioPlayerState extends State<InlineAudioPlayer> {
  late final Player _player = Player();
  StreamSubscription<String>? _errorSubscription;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _errorSubscription = _player.stream.error.listen((String error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.trim().isEmpty ? 'Could not load audio.' : error;
      });
    });
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant InlineAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _player.open(Media(widget.url), play: false);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not load audio.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.title.trim().isNotEmpty) ...<Widget>[
                Text(
                  widget.title.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 10),
              ],
              if (_errorMessage != null)
                Text(
                  _errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (BuildContext context, AsyncSnapshot<bool> playing) {
                    return StreamBuilder<Duration>(
                      stream: _player.stream.position,
                      initialData: _player.state.position,
                      builder: (
                        BuildContext context,
                        AsyncSnapshot<Duration> position,
                      ) {
                        return StreamBuilder<Duration>(
                          stream: _player.stream.duration,
                          initialData: _player.state.duration,
                          builder: (
                            BuildContext context,
                            AsyncSnapshot<Duration> duration,
                          ) {
                            final Duration total =
                                duration.data ?? Duration.zero;
                            final Duration current =
                                position.data ?? Duration.zero;
                            final double totalMs = total.inMilliseconds > 0
                                ? total.inMilliseconds.toDouble()
                                : 1;
                            final double currentMs = current.inMilliseconds
                                .clamp(0, total.inMilliseconds > 0
                                    ? total.inMilliseconds
                                    : 1)
                                .toDouble();
                            return Column(
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    IconButton(
                                      tooltip: playing.data == true
                                          ? 'Pause'
                                          : 'Play',
                                      onPressed: _isLoading
                                          ? null
                                          : _togglePlayback,
                                      icon: Icon(
                                        playing.data == true
                                            ? Icons.pause_circle_outline
                                            : Icons.play_circle_outline,
                                      ),
                                    ),
                                    Expanded(
                                      child: Slider(
                                        min: 0,
                                        max: totalMs,
                                        value: currentMs,
                                        onChanged: total.inMilliseconds <= 0
                                            ? null
                                            : (double value) {
                                                _player.seek(
                                                  Duration(
                                                    milliseconds: value.round(),
                                                  ),
                                                );
                                              },
                                      ),
                                    ),
                                  ],
                                ),
                                Row(
                                  children: <Widget>[
                                    Text(
                                      _formatDuration(current),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    const Spacer(),
                                    Text(
                                      _formatDuration(total),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    final int minutes = (totalSeconds ~/ 60) % 60;
    final int seconds = totalSeconds % 60;
    final int hours = totalSeconds ~/ 3600;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class InlineVideoPlayer extends StatefulWidget {
  const InlineVideoPlayer({
    super.key,
    required this.url,
  });

  final String url;

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errorSubscription;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _errorSubscription = _player.stream.error.listen((String error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.trim().isEmpty ? 'Could not load video.' : error;
      });
    });
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant InlineVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _player.open(Media(widget.url), play: false);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not load video.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_errorMessage != null) {
      return Container(
        width: 280,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          _errorMessage!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 220),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Video(
                    controller: _controller,
                  ),
                ),
                if (_isLoading)
                  const Positioned.fill(
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
