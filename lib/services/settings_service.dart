import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService._();

  late final Future<void> _ready = _loadSettings();
  SettingsService._();

  ThemeMode _themeMode = ThemeMode.dark;
  int _maxConcurrent = 3;
  String _defaultVideoQuality = 'Ask Every Time';
  String _defaultAudioFormat = '320 kbps MP3';
  bool _autoResumeWifi = true;
  bool _hardwareAcceleration = true;
  bool _showAdultRepositories = false;

  // Movie home banner (Netflix-style hero) configuration.
  // style: cinematic | spotlight | poster
  // source: 'current' or '<repoId>|<providerId>'
  String _movieBannerStyle = 'cinematic';
  String _movieBannerSource = 'current';
  bool _movieBannerAutoPlay = true;

  ThemeMode get themeMode => _themeMode;
  int get maxConcurrent => _maxConcurrent;
  String get defaultVideoQuality => _defaultVideoQuality;
  String get defaultAudioFormat => _defaultAudioFormat;
  bool get autoResumeWifi => _autoResumeWifi;
  bool get hardwareAcceleration => _hardwareAcceleration;
  bool get showAdultRepositories => _showAdultRepositories;
  String get movieBannerStyle => _movieBannerStyle;
  String get movieBannerSource => _movieBannerSource;
  bool get movieBannerAutoPlay => _movieBannerAutoPlay;

  /// The available, user-selectable hero styles. Kept here so Settings UI and
  /// the banner itself never drift apart on naming.
  static const List<String> movieBannerStyles = [
    'cinematic',
    'spotlight',
    'poster',
  ];

  /// Completes once the persisted values have been loaded. Mutations await
  /// this first so a slow first read can never overwrite a fresh user change
  /// with the previous launch's defaults.
  Future<void> get ready => _ready;

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final tm = prefs.getString('theme_mode') ?? 'dark';
    if (tm == 'light') {
      _themeMode = ThemeMode.light;
    } else if (tm == 'system') {
      _themeMode = ThemeMode.system;
    } else {
      _themeMode = ThemeMode.dark;
    }

    _maxConcurrent = prefs.getInt('max_concurrent') ?? 3;
    _defaultVideoQuality = prefs.getString('default_video_quality') ?? 'Ask Every Time';
    _defaultAudioFormat = _normalizeAudioFormat(prefs.getString('default_audio_format'));
    _autoResumeWifi = prefs.getBool('auto_resume_wifi') ?? true;
    _hardwareAcceleration = prefs.getBool('hardware_accel') ?? true;
    _showAdultRepositories = prefs.getBool('show_adult_repositories') ?? false;
    final bannerStyle = prefs.getString('movie_banner_style') ?? 'cinematic';
    _movieBannerStyle = movieBannerStyles.contains(bannerStyle)
        ? bannerStyle
        : 'cinematic';
    _movieBannerSource = prefs.getString('movie_banner_source') ?? 'current';
    _movieBannerAutoPlay = prefs.getBool('movie_banner_autoplay') ?? true;
    notifyListeners();
  }

  /// Keeps the audio preference inside the options the settings UI can show.
  /// Older builds offered a misleading "M4A Lossless" choice; migrate it to the
  /// honest M4A/AAC option so a persisted legacy value never reaches the
  /// dropdown (which would assert) and lossy audio is not labelled lossless.
  static String _normalizeAudioFormat(String? value) {
    final text = (value ?? '').trim();
    const options = {'320 kbps MP3', '256 kbps MP3', '128 kbps MP3', 'M4A (AAC)'};
    if (options.contains(text)) return text;
    final lower = text.toLowerCase();
    if (lower.contains('m4a') || lower.contains('lossless')) return 'M4A (AAC)';
    return '320 kbps MP3';
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _ready;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    String tmStr = 'dark';
    if (mode == ThemeMode.light) tmStr = 'light';
    if (mode == ThemeMode.system) tmStr = 'system';
    await prefs.setString('theme_mode', tmStr);
    notifyListeners();
  }

  Future<void> setMaxConcurrent(int count) async {
    await _ready;
    _maxConcurrent = count;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('max_concurrent', count);
    notifyListeners();
  }

  Future<void> setDefaultVideoQuality(String q) async {
    await _ready;
    _defaultVideoQuality = q;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('default_video_quality', q);
    notifyListeners();
  }

  Future<void> setDefaultAudioFormat(String a) async {
    await _ready;
    final value = _normalizeAudioFormat(a);
    _defaultAudioFormat = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('default_audio_format', value);
    notifyListeners();
  }

  Future<void> toggleAutoResumeWifi(bool val) async {
    await _ready;
    _autoResumeWifi = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_resume_wifi', val);
    notifyListeners();
  }

  Future<void> setHardwareAcceleration(bool val) async {
    await _ready;
    _hardwareAcceleration = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hardware_accel', val);
    notifyListeners();
  }

  Future<void> setShowAdultRepositories(bool value) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_adult_repositories', value);
    _showAdultRepositories = value;
    notifyListeners();
  }

  Future<void> setMovieBannerStyle(String style) async {
    await ready;
    final value = movieBannerStyles.contains(style) ? style : 'cinematic';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('movie_banner_style', value);
    _movieBannerStyle = value;
    notifyListeners();
  }

  /// [source] is either 'current' or a 'repoId|providerId' pair.
  Future<void> setMovieBannerSource(String source) async {
    await ready;
    final value = source.trim().isEmpty ? 'current' : source.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('movie_banner_source', value);
    _movieBannerSource = value;
    notifyListeners();
  }

  Future<void> setMovieBannerAutoPlay(bool value) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('movie_banner_autoplay', value);
    _movieBannerAutoPlay = value;
    notifyListeners();
  }
}
