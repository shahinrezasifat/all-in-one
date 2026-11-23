import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Resolves a YouTube channel's original logo once per channel and caches it,
/// so feed cards can show the real avatar instead of a guessed initial.
class ChannelAvatarService {
  ChannelAvatarService._();

  static final ChannelAvatarService instance = ChannelAvatarService._();

  final _cache = <String, Future<String?>>{};
  final _youtube = YoutubeExplode();

  Future<String?> avatarFor(String channelId) {
    if (channelId.isEmpty) return Future.value(null);
    final cached = _cache[channelId];
    if (cached != null) return cached;
    final future = _resolve(channelId);
    _cache[channelId] = future;
    return future;
  }

  Future<String?> _resolve(String channelId) async {
    try {
      final channel = await _youtube.channels
          .get(ChannelId(channelId))
          .timeout(const Duration(seconds: 6));
      return channel.logoUrl.isEmpty ? null : channel.logoUrl;
    } on Exception catch (error) {
      debugPrint('Channel avatar unavailable: $error');
      return null;
    }
  }
}
