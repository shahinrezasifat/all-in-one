import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/site_model.dart';

class BookmarkService extends ChangeNotifier {
  static final BookmarkService instance = BookmarkService._();
  BookmarkService._();

  static const String _storageKey = 'user_saved_bookmarks_v2';
  List<SiteModel> _bookmarks = [];
  bool _isLoaded = false;

  List<SiteModel> get bookmarks => List.unmodifiable(_bookmarks);
  bool get isLoaded => _isLoaded;

  static const List<SiteModel> defaultSites = [
    SiteModel(
      title: 'YouTube',
      url: 'https://m.youtube.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/1384/1384060.png',
      category: 'Video',
      colorHex: 0xFFFF0000,
      isCustom: false,
    ),
    SiteModel(
      title: 'Facebook',
      url: 'https://m.facebook.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/124/124010.png',
      category: 'Social',
      colorHex: 0xFF1877F2,
      isCustom: false,
    ),
    SiteModel(
      title: 'Instagram',
      url: 'https://www.instagram.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/174/174855.png',
      category: 'Social',
      colorHex: 0xFFE1306C,
      isCustom: false,
    ),
    SiteModel(
      title: 'TikTok',
      url: 'https://www.tiktok.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/3046/3046121.png',
      category: 'Shorts',
      colorHex: 0xFF000000,
      isCustom: false,
    ),
    SiteModel(
      title: 'Twitter / X',
      url: 'https://x.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/5969/5969020.png',
      category: 'Social',
      colorHex: 0xFF1DA1F2,
      isCustom: false,
    ),
    SiteModel(
      title: 'SoundCloud',
      url: 'https://soundcloud.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/145/145809.png',
      category: 'Music',
      colorHex: 0xFFFF5500,
      isCustom: false,
    ),
    SiteModel(
      title: 'Vimeo',
      url: 'https://vimeo.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/174/174878.png',
      category: 'Video',
      colorHex: 0xFF1AB7EA,
      isCustom: false,
    ),
    SiteModel(
      title: 'Dailymotion',
      url: 'https://www.dailymotion.com',
      icon: 'https://cdn-icons-png.flaticon.com/512/10091/10091917.png',
      category: 'Video',
      colorHex: 0xFF0066DC,
      isCustom: false,
    ),
  ];

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> decoded = json.decode(raw);
        _bookmarks = decoded.map((e) => SiteModel.fromJson(e)).toList();
      } else {
        _bookmarks = List<SiteModel>.from(defaultSites);
        await _save();
      }
    } catch (e) {
      _bookmarks = List<SiteModel>.from(defaultSites);
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<bool> addBookmark({required String title, required String url}) async {
    await init();
    String cleanUrl = url.trim();
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://$cleanUrl';
    }

    String cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      try {
        final uri = Uri.parse(cleanUrl);
        cleanTitle = uri.host.replaceFirst('www.', '').split('.').first;
        if (cleanTitle.isNotEmpty) {
          cleanTitle = cleanTitle[0].toUpperCase() + cleanTitle.substring(1);
        }
      } catch (_) {
        cleanTitle = 'Bookmark';
      }
    }

    String domain = '';
    try {
      domain = Uri.parse(cleanUrl).host;
    } catch (_) {
      domain = cleanUrl;
    }

    final faviconUrl = domain.isNotEmpty
        ? 'https://www.google.com/s2/favicons?domain=$domain&sz=128'
        : 'https://cdn-icons-png.flaticon.com/512/1006/1006771.png';

    final colors = [
      0xFFFF5722,
      0xFF4CAF50,
      0xFF2196F3,
      0xFF9C27B0,
      0xFFE91E63,
      0xFFFF9800,
      0xFF00BCD4,
      0xFF795548,
    ];
    final color = colors[cleanTitle.hashCode.abs() % colors.length];

    final newSite = SiteModel(
      title: cleanTitle,
      url: cleanUrl,
      icon: faviconUrl,
      category: 'Custom',
      colorHex: color,
      isCustom: true,
    );

    _bookmarks.removeWhere((item) => item.url.toLowerCase() == cleanUrl.toLowerCase());
    _bookmarks.add(newSite);

    await _save();
    notifyListeners();
    return true;
  }

  Future<bool> editBookmark({
    required SiteModel oldSite,
    required String newTitle,
    required String newUrl,
  }) async {
    await init();
    String cleanUrl = newUrl.trim();
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://$cleanUrl';
    }

    String cleanTitle = newTitle.trim();
    if (cleanTitle.isEmpty) {
      cleanTitle = oldSite.title;
    }

    String domain = '';
    try {
      domain = Uri.parse(cleanUrl).host;
    } catch (_) {
      domain = cleanUrl;
    }

    final faviconUrl = domain.isNotEmpty
        ? 'https://www.google.com/s2/favicons?domain=$domain&sz=128'
        : oldSite.icon;

    final updatedSite = SiteModel(
      title: cleanTitle,
      url: cleanUrl,
      icon: faviconUrl,
      category: oldSite.category,
      colorHex: oldSite.colorHex,
      isCustom: true,
    );

    final idx = _bookmarks.indexWhere((item) => item.url == oldSite.url && item.title == oldSite.title);
    if (idx != -1) {
      _bookmarks[idx] = updatedSite;
    } else {
      _bookmarks.add(updatedSite);
    }

    await _save();
    notifyListeners();
    return true;
  }

  Future<void> removeBookmark(SiteModel site) async {
    await init();
    _bookmarks.removeWhere((item) => item.url == site.url && item.title == site.title);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _bookmarks.map((e) => e.toJson()).toList();
      await prefs.setString(_storageKey, json.encode(jsonList));
    } catch (_) {}
  }
}
