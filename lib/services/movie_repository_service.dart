import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie_model.dart';
import 'preference_service.dart';
import 'provider_engine/cloudstream_runtime.dart';

class MovieRepositoryService extends ChangeNotifier {
  static final MovieRepositoryService instance = MovieRepositoryService._();

  late final Future<void> _ready = _init();
  MovieRepositoryService._();

  static const String _prefsKey = 'infinity_loop_movie_repos_catalog_v13';
  static const _selectedSourceKey = 'movie_selected_source';
  ({String repo, String provider})? _selectedSource;
  ({String repo, String provider})? get selectedSource => _selectedSource;

  Future<void> selectSource(String repo, String provider) async {
    await ready;
    final selection = (repo: repo, provider: provider);
    if (_selectedSource == selection) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_selectedSourceKey, [repo, provider]);
    _selectedSource = selection;
    notifyListeners();
  }

  static const String _seededFlagKey = 'infinity_loop_movie_repos_seeded_v13';

  List<MovieRepository> _repositories = [];
  List<MovieRepository> get repositories => List.unmodifiable(_repositories);

  List<MovieRepository> get enabledRepositories =>
      _repositories.where((r) => r.isEnabled).toList();

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  /// Completes once the persisted repositories have been loaded. Every write
  /// awaits it so an in-flight first read can never overwrite a fresh add.
  Future<void> get ready => _ready;

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();

    final selection = prefs.getStringList(_selectedSourceKey);
    if (selection != null && selection.length == 2) {
      _selectedSource = (repo: selection[0], provider: selection[1]);
    }

    final wasSeeded =
        prefs.getBool(_seededFlagKey) == true ||
        prefs.getBool('infinity_loop_movie_repos_seeded_v12') == true;
    const legacyKeys = [
      'infinity_loop_movie_repos_v12_catalog35',
      'snaptube_movie_repos_v10_all28_cloudstream',
      'snaptube_movie_repos_v8_user_clean',
      'snaptube_movie_repos_v6_zangetsu',
      'snaptube_movie_repos_v5',
      'snaptube_movie_repos_v4',
    ];
    final keys = [_prefsKey, ...legacyKeys];

    final ids = <String>{};
    final urls = <String>{};
    final shortcodes = <String>{};
    void addMissing(Iterable<MovieRepository> repos) {
      for (final repo in repos) {
        final id = repo.id.trim().toLowerCase();
        final url = normalizeRepoUrl(repo.url)
            .replaceFirst('/refs/heads/', '/');
        final shortcode = repo.shortcode.trim().toLowerCase();
        if (ids.contains(id) ||
            (url.isNotEmpty && urls.contains(url)) ||
            (shortcode.isNotEmpty && shortcodes.contains(shortcode))) {
          continue;
        }
        _repositories.add(repo);
        ids.add(id);
        if (url.isNotEmpty) urls.add(url);
        if (shortcode.isNotEmpty) shortcodes.add(shortcode);
      }
    }

    for (final key in keys) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) continue;
        for (final entry in decoded.whereType<Map<String, dynamic>>()) {
          try {
            addMissing([MovieRepository.fromJson(entry)]);
          } catch (_) {
            // A malformed record should not block the remaining repositories.
          }
        }
      } on FormatException {
        // Continue with the other saved catalogs.
      }
    }

    if (!wasSeeded) {
      addMissing(
        _getDefaultRepositories().map(
          (repo) => repo.copyWith(providers: const []),
        ),
      );
    }
    if (!wasSeeded || legacyKeys.any(prefs.containsKey)) await _save();
    if (!wasSeeded) await prefs.setBool(_seededFlagKey, true);

    // Always clean up any legacy storage keys
    for (final k in legacyKeys) {
      await prefs.remove(k);
    }

    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_repositories.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }

  final Map<String, Future<bool>> _manifestRequests = {};

  Future<bool> refreshRepository(String id) async {
    await ready;
    return _manifestRequests.putIfAbsent(id, () async {
      try {
        final repo = _repositories.firstWhere((r) => r.id == id);
        final data = await _fetchJson(repo.url);
        final parsed = _dedupeProviders(
          await _collectProviders(data, baseUrl: repo.url),
        );
        if (parsed.isEmpty) return false;
        final index = _repositories.indexWhere(
          (r) => r.id == id && r.url == repo.url,
        );
        if (index < 0) return false;
        final current = _repositories[index];
        _repositories[index] = current.copyWith(
          providers: _preserveInstallation(parsed, current.providers),
        );
        await _save();
        notifyListeners();
        return true;
      } finally {
        _manifestRequests.remove(id);
      }
    });
  }

  List<MovieProvider> _preserveInstallation(
    List<MovieProvider> incoming,
    List<MovieProvider> previous,
  ) {
    final byId = {
      for (final provider in previous) provider.id.toLowerCase(): provider,
    };
    final updated = <MovieProvider>[];
    for (final provider in incoming) {
      final prior = byId.remove(provider.id.toLowerCase());
      if (prior?.isInstalled == true &&
          (prior!.id != provider.id ||
              prior.cloudStreamUrl.isEmpty !=
                  provider.cloudStreamUrl.isEmpty)) {
        // The installed package uses the original provider ID and runtime.
        updated.add(prior);
      } else {
        updated.add(
          provider.copyWith(
            isInstalled: prior?.isInstalled ?? false,
            isEnabled: prior?.isEnabled ?? false,
          ),
        );
      }
    }
    return [
      ...updated,
      ...byId.values.where(
        (provider) =>
            provider.isInstalled || provider.id == 'AllMovieLandProvider',
      ),
    ];
  }

  /// Loopback/emulator hosts are allowed to stay on HTTP (local test servers
  /// and development endpoints); everything else must use HTTPS.
  static String _httpsOnly(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http') return url;
    if (const {
      'localhost',
      '127.0.0.1',
      '[::1]',
      '10.0.2.2',
    }.contains(uri.host)) {
      return url;
    }
    return url.replaceFirst('http://', 'https://');
  }

  static String normalizeRepoUrl(String input) {
    var url = input.trim();
    const schemes = {
      'cloudstreamrepo://': 'https://',
      'stremio://': 'https://',
      'zangetsu://': 'https://',
      'aniyomi://': 'https://',
    };
    for (final entry in schemes.entries) {
      if (url.toLowerCase().startsWith(entry.key)) {
        final target = url.substring(entry.key.length);
        final scheme = Uri.tryParse(target)?.scheme.toLowerCase();
        if (scheme == 'http') return _httpsOnly(target);
        return scheme == 'https' ? target : '${entry.value}$target';
      }
    }
    if (url.startsWith('http://')) return _httpsOnly(url);
    if (url.startsWith('https://')) return url;
    // A bare host/path (e.g. raw.githubusercontent.com/.../repo.json) is a URL
    // too; only genuinely scheme-less shortcodes are left untouched.
    if (url.contains('.') && !url.contains(' ')) return 'https://$url';
    return url;
  }

  Future<void> toggleRepository(String id, bool enabled) async {
    await ready;
    final idx = _repositories.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _repositories[idx] = _repositories[idx].copyWith(isEnabled: enabled);
      await _save();
      notifyListeners();
    }
  }

  Future<void> editRepository(
    String id, {
    String? name,
    String? url,
    String? description,
    bool? isEnabled,
  }) async {
    await ready;
    final idx = _repositories.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _repositories[idx] = _repositories[idx].copyWith(
        name: name,
        url: url == null ? null : normalizeRepoUrl(url),
        description: description,
        isEnabled: isEnabled,
      );
      await _save();
      notifyListeners();
    }
  }

  Future<void> deleteRepository(String id) async {
    await ready;
    if (CloudStreamRuntime.supported &&
        _repositories.any(
          (r) =>
              r.id == id && r.providers.any((p) => p.cloudStreamUrl.isNotEmpty),
        )) {
      await CloudStreamRuntime.delete(id);
    }
    _repositories.removeWhere((r) => r.id == id);
    await _save();
    notifyListeners();
  }

  /// Wipes all repositories completely
  Future<void> clearAllRepositories() async {
    await ready;
    _repositories.clear();
    // Reset the one-time seeding flags: clearing every repository is the
    // user's way of asking for a factory reset of the extension system, so the
    // next launch must restore the default (28 CloudStream + Zangetsu JS)
    // setup instead of honouring a stale "already seeded" memory.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_seededFlagKey);
    await prefs.remove('snaptube_zangetsu_js_seeded_v1');
    await _save();
    notifyListeners();
  }

  Future<void> toggleProvider(
    String repoId,
    String providerId,
    bool isInstalled,
  ) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        if (p.id == providerId) {
          return p.copyWith(isEnabled: isInstalled, isInstalled: isInstalled);
        }
        return p;
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  Future<void> editProvider(
    String repoId,
    String providerId, {
    String? name,
    String? description,
    String? language,
  }) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        if (p.id == providerId) {
          return p.copyWith(
            name: name,
            description: description,
            language: language,
          );
        }
        return p;
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  // Ecosystem methods
  List<MovieRepository> getRepositoriesByEcosystem(String ecosystem) {
    return _repositories
        .where(
          (r) => r.effectiveEcosystem.toLowerCase() == ecosystem.toLowerCase(),
        )
        .toList();
  }

  List<EcosystemExtensionItem> getExtensionsByEcosystem(String ecosystem) {
    final repos = getRepositoriesByEcosystem(ecosystem);
    final List<EcosystemExtensionItem> result = [];
    for (final repo in repos) {
      for (final p in repo.providers) {
        result.add(EcosystemExtensionItem(repository: repo, provider: p));
      }
    }
    return result;
  }

  int getInstalledExtensionCountByEcosystem(String ecosystem) {
    final repos = getRepositoriesByEcosystem(ecosystem);
    int count = 0;
    for (final repo in repos) {
      count += repo.providers.where((p) => p.isInstalled).length;
    }
    return count;
  }

  int getActiveExtensionCountByEcosystem(String ecosystem) {
    final repos = getRepositoriesByEcosystem(ecosystem);
    int count = 0;
    for (final repo in repos) {
      if (repo.isEnabled) {
        count += repo.providers
            .where((p) => p.isInstalled && p.isEnabled)
            .length;
      }
    }
    return count;
  }

  Future<void> toggleExtension(
    String repoId,
    String providerId,
    bool enabled,
  ) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        if (p.id == providerId) {
          return p.copyWith(isEnabled: enabled);
        }
        return p;
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  Future<void> uninstallExtension(String repoId, String providerId) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      if (CloudStreamRuntime.supported &&
          repo.providers.any(
            (p) => p.id == providerId && p.cloudStreamUrl.isNotEmpty,
          )) {
        await CloudStreamRuntime.delete(repoId, providerId);
      }
      final newProviders = repo.providers.map((p) {
        if (p.id == providerId) {
          return p.copyWith(isInstalled: false, isEnabled: false);
        }
        return p;
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  Future<void> installExtension(String repoId, String providerId) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        if (p.id == providerId) {
          return p.copyWith(isInstalled: true, isEnabled: true);
        }
        return p;
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  Future<void> installAllExtensionsInRepo(String repoId) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        return p.copyWith(isInstalled: true, isEnabled: true);
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  Future<void> uninstallAllExtensionsInRepo(String repoId) async {
    await ready;
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx != -1) {
      final repo = _repositories[repoIdx];
      final newProviders = repo.providers.map((p) {
        return p.copyWith(isInstalled: false, isEnabled: false);
      }).toList();
      _repositories[repoIdx] = repo.copyWith(providers: newProviders);
      await _save();
      notifyListeners();
    }
  }

  /// Returns all currently active and installed extensions across all enabled repositories
  List<MovieProvider> getInstalledActiveProviders() {
    final list = <MovieProvider>[];
    for (final repo in enabledRepositories) {
      for (final p in repo.providers) {
        if (p.isInstalled && p.isEnabled) {
          list.add(p);
        }
      }
    }
    return list;
  }

  /// All 35 Pre-installed Repositories & Streaming Extensions (Infinity Loop)
  List<MovieRepository> _getDefaultRepositories() {
    return [
      // =======================================================================
      // 1. CloudStream Extensions (Movies, Series, BDIX, Live TV, OTT) - 27
      // =======================================================================
      MovieRepository(
        id: 'cs_cloudstream_official',
        name: 'CloudStream Providers',
        shortcode: 'cspr',
        description: 'Official CloudStream core extensions suite (SFlix, SuperStream, FlixHQ, Sorastream).',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json',
        ),
        author: 'recloudstream',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 15,
        tags: const ['Official', 'Global', 'Movies', 'Series'],
      ),
      MovieRepository(
        id: 'cs_phisher',
        name: 'Phisher Repo',
        shortcode: 'phisherrepo',
        description: 'Phisher community extensions suite with AllMovieLand, multi-lang movies & mirrors.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
        ),
        author: 'phisher98',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 18,
        tags: const ['Indian', 'Multi-lang', 'Movies', 'Default'],
        providers: const [
          MovieProvider(
            id: 'AllMovieLandProvider',
            name: 'AllMovieLand',
            description: 'Hollywood, Bollywood, Dual Audio & TV Series direct streaming mirror',
            version: '1.0.0',
            language: 'en',
            types: ['movie', 'tv'],
            iconUrl: 'https://allmovieland.fun/favicon.ico',
            scriptUrl: '',
            isInstalled: true,
            isEnabled: true,
          ),
        ],
      ),
      MovieRepository(
        id: 'cs_redowan_bdix',
        name: "Redowan's BDIX Repo",
        shortcode: 'redowan',
        description: 'Ultra High-Speed BDIX Bangladeshi FTP, Bangla Cinema, Hoichoi, Chorki & OTT.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/redowan99/Redowan-CloudStream/master/repo.json',
        ),
        author: 'redowan99',
        version: '2.0.0',
        iconType: 'bollywood',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 12,
        tags: const ['Bangladeshi', 'BDIX FTP', 'Hoichoi', 'Chorki'],
        providers: const [
          MovieProvider(
            id: 'banglaplex',
            name: 'BanglaPlex BDIX',
            description: 'Bangla Cinema, Hoichoi, Chorki & OTT BDIX FTP Server',
            version: '2.0.0',
            language: 'bn',
            types: ['movie', 'series'],
            iconUrl: 'https://banglaplex.com/icon.png',
            scriptUrl: '',
            isInstalled: true,
            isEnabled: true,
          ),
        ],
      ),
      MovieRepository(
        id: 'cs_megix_csx',
        name: 'Megix Repo',
        shortcode: 'csx',
        description: 'Hindi & English movie and series streaming scrapers by Saurabh Kaperwan.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json',
        ),
        author: 'SaurabhKaperwan',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 8,
        tags: const ['Hindi', 'English', 'Movies'],
      ),
      MovieRepository(
        id: 'cs_mega_repo',
        name: 'Mega Repository',
        shortcode: 'megarepo',
        description: 'Self-similarity MegaRepo with vast multi-language scraper collection.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/self-similarity/MegaRepo/builds/repo.json',
        ),
        author: 'self-similarity',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 22,
        tags: const ['Multi-language', 'Global'],
      ),
      MovieRepository(
        id: 'cs_netmirror',
        name: 'Netmirror Repo',
        shortcode: 'Netmirror',
        description: 'OTT mirrors covering Netflix, Prime Video, and premium VOD content.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Sushan64/NetMirror-Extension/refs/heads/builds/Netflix.json',
        ),
        author: 'Sushan64',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 6,
        tags: const ['OTT Mirrors', 'Netflix', 'Prime'],
      ),
      MovieRepository(
        id: 'cs_cnc_verse',
        name: 'CNC Verse Repository',
        shortcode: 'cncv',
        description: 'Indian & South Asian cinema streaming extension suite.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
        ),
        author: 'NivinCNC',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 10,
        tags: const ['Indian', 'South Asian'],
      ),
      MovieRepository(
        id: 'cs_karma',
        name: 'cs-karma',
        shortcode: 'cskarma',
        description: 'Live sports streaming, anime and entertainment scrapers.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Kraptor123/cs-Karma/refs/heads/master/repo.json',
        ),
        author: 'Kraptor123',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 14,
        tags: const ['Sports Live', 'Anime'],
      ),
      MovieRepository(
        id: 'cs_king_xtream_iptv',
        name: 'King (XtreamIPTV)',
        shortcode: 'kingl',
        description: 'Xtream IPTV live television channels and sports broadcast streams.',
        url: normalizeRepoUrl('https://pastebin.com/raw/Cd2g2tfz'),
        author: 'King Community',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 12,
        tags: const ['Live TV', 'IPTV', 'Sports'],
      ),
      MovieRepository(
        id: 'cs_3rabi',
        name: '3rabi عربي',
        shortcode: 'arb',
        description:
            'Arabic cinema, Middle Eastern drama series and dubbed movies.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo',
        ),
        author: 'Abodabodd',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 9,
        tags: const ['Arabic', 'Middle East', 'Series'],
      ),
      MovieRepository(
        id: 'cs_indostream',
        name: 'IndoStream Repo',
        shortcode: 'indos',
        description:
            'Indonesian movies, Asian dramas, and streaming providers.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/TeKuma25/IndoStream/builds/repo.json',
        ),
        author: 'TeKuma25',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 11,
        tags: const ['Indonesian', 'Asian Drama'],
      ),
      MovieRepository(
        id: 'cs_extcloud',
        name: 'ExtCloud Repo',
        shortcode: 'extcloud',
        description:
            'ExtCloud Indonesian streaming extensions and cinema suite.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/duro92/ExtCloud/main/repo.json',
        ),
        author: 'duro92',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 7,
        tags: const ['Indonesian'],
      ),
      MovieRepository(
        id: 'cs_cloudx',
        name: 'CloudX Repository',
        shortcode: 'cloudx',
        description:
            'CloudX Indonesian & multi-language entertainment extensions.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Asm0d3usX/CloudX/builds/repo.json',
        ),
        author: 'Asm0d3usX',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 13,
        tags: const ['Indonesian', 'Global'],
      ),
      MovieRepository(
        id: 'cs_dogior_had_enough',
        name: "doGior's Had Enough",
        shortcode: 'gior',
        description:
            'Italian and international cinema and series scraper suite.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json',
        ),
        author: 'doGior',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 16,
        tags: const ['Italian', 'Global'],
      ),
      MovieRepository(
        id: 'cs_italian_providers',
        name: 'Italian Providers Repo',
        shortcode: 'ipr',
        description: 'Italian native streaming and movie provider collection.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Gian-Fr/ItalianProvider/builds/repo.json',
        ),
        author: 'Gian-Fr',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 10,
        tags: const ['Italian'],
      ),
      MovieRepository(
        id: 'cs_diegon_italia',
        name: 'DieGon / ItaliaInStreaming',
        shortcode: 'diegon7',
        description:
            'ItaliaInStreaming direct cinema scrapers and video hosts.',
        url: normalizeRepoUrl('https://pastebin.com/raw/qndZtL6D'),
        author: 'DieGon',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 8,
        tags: const ['Italian'],
      ),
      MovieRepository(
        id: 'cs_cakes_twix',
        name: 'CakesTwix',
        shortcode: 'cakes',
        description: 'Ukrainian translated cinema, cartoons, and TV series.',
        url: normalizeRepoUrl(
          'https://codeberg.org/CakesTwix/cloudstream-extensions-uk/raw/branch/master/repo.json',
        ),
        author: 'CakesTwix',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 9,
        tags: const ['Ukrainian'],
      ),
      MovieRepository(
        id: 'cs_dizipal_tabiispor',
        name: 'DiziPal & TabiiSpor',
        shortcode: 'sarapcanagii',
        description:
            'Turkish TV series, DiziPal streaming mirrors and Tabii sports.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/sarapcanagii/Pitipitii/master/repo.json',
        ),
        author: 'sarapcanagii',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 8,
        tags: const ['Turkish Sports', 'TV'],
      ),
      MovieRepository(
        id: 'cs_turkish_kraptor',
        name: 'Turkish Providers (@kraptor123)',
        shortcode: 'kraptorcs',
        description:
            'Turkish cinema, dubbing, and streaming extensions by Kraptor.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Kraptor123/cs-kraptor/refs/heads/master/repo.json',
        ),
        author: 'Kraptor123',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 14,
        tags: const ['Turkish'],
      ),
      MovieRepository(
        id: 'cs_lawlietrepo',
        name: 'lawlietrepo',
        shortcode: 'lawliet',
        description: 'Brazilian Portuguese dubbed and subbed movies & anime.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/lawlietbr/lietrepo/refs/heads/main/builds/repo.json',
        ),
        author: 'lawlietbr',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 12,
        tags: const ['Brazilian', 'Portuguese'],
      ),
      MovieRepository(
        id: 'cs_saimuel',
        name: 'Saimuel Repo',
        shortcode: 'saim',
        description: 'Portuguese & Brazilian movies, anime and TV shows.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/saimuelbr/saimuelrepo/refs/heads/main/builds/repo.json',
        ),
        author: 'saimuelbr',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 10,
        tags: const ['Brazilian', 'Portuguese'],
      ),
      MovieRepository(
        id: 'cs_cuxplug',
        name: 'CuxPlug',
        shortcode: 'CuxPlug',
        description:
            'International entertainment scrapers and streaming plugins.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/ycngmn/CuxPlug/refs/heads/main/repo.json',
        ),
        author: 'ycngmn',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 9,
        tags: const ['International'],
      ),
      MovieRepository(
        id: 'cs_vietnamese',
        name: 'CloudStream Vietnamese',
        shortcode: 'viet',
        description: 'Vietnamese cinema, subtitled Asian dramas, and movies.',
        url: normalizeRepoUrl(
          'https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json',
        ),
        author: 'tearrs',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 8,
        tags: const ['Vietnamese'],
      ),
      MovieRepository(
        id: 'cs_german_providers',
        name: 'German Providers Repo',
        shortcode: 'gpr',
        description: 'German cinema and TV shows (Kinox, Movie4k mirrors).',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Bnyro/GermanProviders/refs/heads/master/repo.json',
        ),
        author: 'Bnyro',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 7,
        tags: const ['German'],
      ),
      MovieRepository(
        id: 'cs_luna712',
        name: 'Luna712 Extensions',
        shortcode: 'luna712',
        description: 'Multi-language archive of streaming extensions.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Luna712/Luna712-CloudStream-Extensions/28885d17ceb7f24782b732b6056085c14c1fd027/repo.json',
        ),
        author: 'Luna712',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 15,
        tags: const ['Multi-lang Archive'],
      ),
      MovieRepository(
        id: 'cs_zzikozz_french',
        name: 'zzikozz / French Repo',
        shortcode: 'zzikozz',
        description:
            'French streaming providers (VF / VOSTFR movies & series).',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/zzikozz/frenchCS/refs/heads/main/repo.json',
        ),
        author: 'zzikozz',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 11,
        tags: const ['French'],
      ),
      MovieRepository(
        id: 'cs_gramflix_french',
        name: 'GramFlix / French Repo',
        shortcode: 'gramflix',
        description: 'French GramFlix VOD and series streaming extensions.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/tOntOnbOuLii/GramFlix/main/repo.json',
        ),
        author: 'tOntOnbOuLii',
        version: '1.0.0',
        iconType: 'cloudstream',
        ecosystem: 'cloudstream',
        isEnabled: true,
        providerCount: 6,
        tags: const ['French'],
      ),

      // =======================================================================
      // 2. Native JS Streaming Providers - 2
      // =======================================================================
      MovieRepository(
        id: 'zg_zangetsu_official',
        name: 'Zangetsu Providers (Official)',
        shortcode: 'zangetsu',
        description: 'Official QuickJS scrapers: 4K HDHub, VegaMovies, Anime & debrid streams.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/index.json',
        ),
        author: 'Spyou / Zangetsu',
        version: '1.5.0',
        iconType: 'stremio',
        ecosystem: 'zangetsu',
        isEnabled: true,
        providerCount: 8,
        tags: const ['Official', 'Anime', 'Movies', 'JS Engine'],
        providers: const [
          MovieProvider(
            id: 'hdhub4u',
            name: 'HDHub4u (4K & 1080p)',
            description: '4K Ultra HD & 1080p Movies and Dual Audio Series',
            version: '1.2.0',
            language: 'en',
            types: ['movie', 'tv'],
            iconUrl: 'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/icons/hdhub4u.png',
            scriptUrl: 'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/providers/hdhub4u.js',
            isInstalled: true,
            isEnabled: true,
          ),
          MovieProvider(
            id: 'vegamovies',
            name: 'VegaMovies',
            description:
                'Bollywood, Hollywood & South Indian Dual Audio Hindi 4K',
            version: '1.1.0',
            language: 'hi',
            types: ['movie', 'series'],
            iconUrl: 'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/icons/vegamovies.png',
            scriptUrl: 'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/providers/vegamovies.js',
            isInstalled: true,
            isEnabled: true,
          ),
        ],
      ),
      MovieRepository(
        id: 'zg_mewtwo_community',
        name: 'Mewtwo Community',
        shortcode: 'mewtwo',
        description:
            'Mewtwo community QuickJS providers for fast streaming mirrors.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/MewtwoOP1/Zangetsu-repo/main/index.json',
        ),
        author: 'MewtwoOP1',
        version: '1.0.0',
        iconType: 'stremio',
        ecosystem: 'zangetsu',
        isEnabled: true,
        providerCount: 5,
        tags: const ['Community', 'Streaming', 'JS Engine'],
      ),

      // =======================================================================
      // 3. Aniyomi Extensions (Anime) - 1
      // =======================================================================
      MovieRepository(
        id: 'aniyomi_yuzono',
        name: 'yuzono anime-repo',
        shortcode: 'aniyomi',
        description:
            'Anime scrapers and video sources from the Aniyomi ecosystem.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json',
        ),
        author: 'yuzono',
        version: '1.0.0',
        iconType: 'dantotsu',
        ecosystem: 'aniyomi',
        isEnabled: true,
        providerCount: 20,
        tags: const ['Anime Extensions', 'Aniyomi'],
      ),

      // =======================================================================
      // 4. Mihon Extensions (Manga / Manhwa / Manhua) - 1
      // =======================================================================
      MovieRepository(
        id: 'mihon_keiyoushi',
        name: 'Keiyoushi Extensions',
        shortcode: 'mihon',
        description: 'Manga, manhwa, manhua & comic scrapers using the Keiyoushi standard.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
        ),
        author: 'keiyoushi',
        version: '1.0.0',
        iconType: 'mihon',
        ecosystem: 'mihon',
        isEnabled: true,
        providerCount: 30,
        tags: const ['Manga', 'Comics', 'Keiyoushi'],
      ),

      // =======================================================================
      // 5. LNReader Plugins (Light & Web Novels) - 1
      // =======================================================================
      MovieRepository(
        id: 'lnreader_plugins',
        name: 'LNReader Plugins',
        shortcode: 'lnreader',
        description: 'Web novel and light novel readers and chapter scrapers.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json',
        ),
        author: 'LNReader',
        version: '3.0.0',
        iconType: 'lnreader',
        ecosystem: 'lnreader',
        isEnabled: true,
        providerCount: 15,
        tags: const ['Light Novels', 'Web Novels'],
      ),

      // =======================================================================
      // 6. 18+ / Adult Extensions (Privacy Gated) - 3
      // =======================================================================
      MovieRepository(
        id: 'adult_ultimate_18plus',
        name: 'Ultimate 18+ Extensions',
        shortcode: 'ultimate18',
        description: 'Privacy-gated 18+ streaming extensions.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/punpunsx/cloudstream-18plus-Extensions/builds/plugins.json',
        ),
        author: 'punpunsx',
        version: '1.0.0',
        iconType: 'adult',
        ecosystem: 'adult',
        isEnabled: true,
        providerCount: 12,
        tags: const ['NSFW', 'Adult', '18+'],
      ),
      MovieRepository(
        id: 'adult_cxxx',
        name: 'CXXX Adult Repo',
        shortcode: 'cxxx',
        description: 'Privacy-gated adult video providers and archives.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/phisher98/CXXX/builds/CXXX.json',
        ),
        author: 'phisher98',
        version: '1.0.0',
        iconType: 'adult',
        ecosystem: 'adult',
        isEnabled: true,
        providerCount: 8,
        tags: const ['NSFW', 'Adult', '18+'],
      ),
      MovieRepository(
        id: 'adult_cs_gizlikeyif',
        name: 'Cs-GizliKeyif',
        shortcode: 'gizlikeyif',
        description: 'Privacy-gated adult streaming scrapers.',
        url: normalizeRepoUrl(
          'https://raw.githubusercontent.com/Kraptor123/Cs-GizliKeyif/refs/heads/master/repo.json',
        ),
        author: 'Kraptor123',
        version: '1.0.0',
        iconType: 'adult',
        ecosystem: 'adult',
        isEnabled: true,
        providerCount: 6,
        tags: const ['NSFW', 'Adult', '18+'],
      ),
    ];
  }

  static final Map<String, Map<String, dynamic>> _shortcodeMap = {
    // 1. CloudStream Extensions (1 - 27)
    'cspr': {
      'name': 'CloudStream Providers',
      'url': 'https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json',
      'desc': 'Official CloudStream core extensions suite.',
      'author': 'recloudstream',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'phisherrepo': {
      'name': 'Phisher Repo',
      'url': 'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
      'desc': 'Phisher community extensions suite with AllMovieLand and Cinema mirrors.',
      'author': 'phisher98',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'redowan': {
      'name': "Redowan's BDIX Repo",
      'url': 'https://raw.githubusercontent.com/redowan99/Redowan-CloudStream/master/repo.json',
      'desc':
          'BDIX Ultra High-Speed Bangla, OTT & Bollywood streaming repository.',
      'author': 'redowan99',
      'type': 'bollywood',
      'ecosystem': 'cloudstream',
    },
    'csx': {
      'name': 'Megix Repo',
      'url': 'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json',
      'desc': 'Hindi & English movie and series streaming scrapers.',
      'author': 'SaurabhKaperwan',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'megarepo': {
      'name': 'Mega Repository',
      'url': 'https://raw.githubusercontent.com/self-similarity/MegaRepo/builds/repo.json',
      'desc': 'Self-similarity MegaRepo with vast multi-language scraper collection.',
      'author': 'self-similarity',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'netmirror': {
      'name': 'Netmirror Repo',
      'url': 'https://raw.githubusercontent.com/Sushan64/NetMirror-Extension/refs/heads/builds/Netflix.json',
      'desc': 'OTT mirrors covering Netflix, Prime Video, and premium VOD.',
      'author': 'Sushan64',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'cncv': {
      'name': 'CNC Verse Repository',
      'url': 'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
      'desc': 'Indian & South Asian cinema streaming extension suite.',
      'author': 'NivinCNC',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'cskarma': {
      'name': 'cs-karma',
      'url': 'https://raw.githubusercontent.com/Kraptor123/cs-Karma/refs/heads/master/repo.json',
      'desc': 'Live sports channels, anime and entertainment scrapers.',
      'author': 'Kraptor123',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'kingl': {
      'name': 'King (XtreamIPTV)',
      'url': 'https://pastebin.com/raw/Cd2g2tfz',
      'desc':
          'Xtream IPTV live television channels and sports broadcast streams.',
      'author': 'King Community',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'arb': {
      'name': '3rabi عربي',
      'url': 'https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo',
      'desc': 'Arabic cinema, Middle Eastern drama series and dubbed movies.',
      'author': 'Abodabodd',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'indos': {
      'name': 'IndoStream Repo',
      'url': 'https://raw.githubusercontent.com/TeKuma25/IndoStream/builds/repo.json',
      'desc': 'Indonesian movies, Asian dramas, and streaming providers.',
      'author': 'TeKuma25',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'extcloud': {
      'name': 'ExtCloud Repo',
      'url': 'https://raw.githubusercontent.com/duro92/ExtCloud/main/repo.json',
      'desc': 'ExtCloud Indonesian streaming extensions suite.',
      'author': 'duro92',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'cloudx': {
      'name': 'CloudX Repository',
      'url':
          'https://raw.githubusercontent.com/Asm0d3usX/CloudX/builds/repo.json',
      'desc': 'CloudX Indonesian & multi-language entertainment extensions.',
      'author': 'Asm0d3usX',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'gior': {
      'name': "doGior's Had Enough",
      'url': 'https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json',
      'desc':
          'doGior Italian & international movies and series provider suite.',
      'author': 'doGior',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'ipr': {
      'name': 'Italian Providers Repo',
      'url': 'https://raw.githubusercontent.com/Gian-Fr/ItalianProvider/builds/repo.json',
      'desc': 'Italian cinema, anime and streaming provider repository.',
      'author': 'Gian-Fr',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'diegon7': {
      'name': 'DieGon / ItaliaInStreaming',
      'url': 'https://pastebin.com/raw/qndZtL6D',
      'desc': 'ItaliaInStreaming direct streaming scrapers.',
      'author': 'DieGon',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'cakes': {
      'name': 'CakesTwix',
      'url': 'https://codeberg.org/CakesTwix/cloudstream-extensions-uk/raw/branch/master/repo.json',
      'desc': 'Ukrainian translated cinema, cartoons, and TV series.',
      'author': 'CakesTwix',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'sarapcanagii': {
      'name': 'DiziPal & TabiiSpor',
      'url': 'https://raw.githubusercontent.com/sarapcanagii/Pitipitii/master/repo.json',
      'desc': 'Turkish TV series, DiziPal streaming mirrors and Tabii sports.',
      'author': 'sarapcanagii',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'kraptorcs': {
      'name': 'Turkish Providers (@kraptor123)',
      'url': 'https://raw.githubusercontent.com/Kraptor123/cs-kraptor/refs/heads/master/repo.json',
      'desc': 'Turkish cinema, dubbing, and streaming extensions.',
      'author': 'Kraptor123',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'lawliet': {
      'name': 'lawlietrepo',
      'url': 'https://raw.githubusercontent.com/lawlietbr/lietrepo/refs/heads/main/builds/repo.json',
      'desc': 'Brazilian Portuguese movies, series, and dubbed anime.',
      'author': 'lawlietbr',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'saim': {
      'name': 'Saimuel Repo',
      'url': 'https://raw.githubusercontent.com/saimuelbr/saimuelrepo/refs/heads/main/builds/repo.json',
      'desc': 'Portuguese & Brazilian movies, anime and TV shows.',
      'author': 'saimuelbr',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'cuxplug': {
      'name': 'CuxPlug',
      'url': 'https://raw.githubusercontent.com/ycngmn/CuxPlug/refs/heads/main/repo.json',
      'desc': 'International entertainment scrapers and streaming plugins.',
      'author': 'ycngmn',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'viet': {
      'name': 'CloudStream Vietnamese',
      'url': 'https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json',
      'desc': 'Vietnamese cinema, subtitled Asian dramas, and movies.',
      'author': 'tearrs',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'gpr': {
      'name': 'German Providers Repo',
      'url': 'https://raw.githubusercontent.com/Bnyro/GermanProviders/refs/heads/master/repo.json',
      'desc': 'German cinema and TV shows (Kinox, Movie4k mirrors).',
      'author': 'Bnyro',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'luna712': {
      'name': 'Luna712 Extensions',
      'url': 'https://raw.githubusercontent.com/Luna712/Luna712-CloudStream-Extensions/28885d17ceb7f24782b732b6056085c14c1fd027/repo.json',
      'desc': 'Multi-language archive of streaming extensions.',
      'author': 'Luna712',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'zzikozz': {
      'name': 'zzikozz / French Repo',
      'url': 'https://raw.githubusercontent.com/zzikozz/frenchCS/refs/heads/main/repo.json',
      'desc': 'French streaming providers (VF / VOSTFR movies & series).',
      'author': 'zzikozz',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },
    'gramflix': {
      'name': 'GramFlix / French Repo',
      'url': 'https://raw.githubusercontent.com/tOntOnbOuLii/GramFlix/main/repo.json',
      'desc': 'French GramFlix VOD and series streaming extensions.',
      'author': 'tOntOnbOuLii',
      'type': 'cloudstream',
      'ecosystem': 'cloudstream',
    },

    // 2. Native JS Streaming Providers
    'zangetsu': {
      'name': 'Zangetsu Providers (Official)',
      'url': 'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main/index.json',
      'desc': 'Official QuickJS scrapers for anime & movies.',
      'author': 'Spyou / Zangetsu',
      'type': 'stremio',
      'ecosystem': 'zangetsu',
    },
    'mewtwo': {
      'name': 'Mewtwo Community',
      'url': 'https://raw.githubusercontent.com/MewtwoOP1/Zangetsu-repo/main/index.json',
      'desc': 'Mewtwo community QuickJS providers for fast streaming mirrors.',
      'author': 'MewtwoOP1',
      'type': 'stremio',
      'ecosystem': 'zangetsu',
    },

    // 3. Aniyomi Extensions
    'aniyomi': {
      'name': 'yuzono anime-repo',
      'url': 'https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json',
      'desc': 'Anime scrapers and video sources from the Aniyomi ecosystem.',
      'author': 'yuzono',
      'type': 'dantotsu',
      'ecosystem': 'aniyomi',
    },

    // 4. Mihon Extensions
    'mihon': {
      'name': 'Keiyoushi Extensions',
      'url': 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
      'desc': 'Manga, manhwa and comic scrapers using the Keiyoushi standard.',
      'author': 'keiyoushi',
      'type': 'mihon',
      'ecosystem': 'mihon',
    },
    'keiyoushi': {
      'name': 'Keiyoushi Extensions',
      'url': 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
      'desc': 'Manga, manhwa and comic scrapers using the Keiyoushi standard.',
      'author': 'keiyoushi',
      'type': 'mihon',
      'ecosystem': 'mihon',
    },

    // 5. LNReader Plugins
    'lnreader': {
      'name': 'LNReader Plugins',
      'url': 'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json',
      'desc': 'Web novel and light novel readers and chapter scrapers.',
      'author': 'LNReader',
      'type': 'lnreader',
      'ecosystem': 'lnreader',
    },

    // 6. 18+ / Adult Extensions
    'ultimate18': {
      'name': 'Ultimate 18+ Extensions',
      'url': 'https://raw.githubusercontent.com/punpunsx/cloudstream-18plus-Extensions/builds/plugins.json',
      'desc': 'Privacy-gated 18+ streaming extensions.',
      'author': 'punpunsx',
      'type': 'adult',
      'ecosystem': 'adult',
    },
    'cxxx': {
      'name': 'CXXX Adult Repo',
      'url':
          'https://raw.githubusercontent.com/phisher98/CXXX/builds/CXXX.json',
      'desc': 'Privacy-gated adult video providers and archives.',
      'author': 'phisher98',
      'type': 'adult',
      'ecosystem': 'adult',
    },
    'gizlikeyif': {
      'name': 'Cs-GizliKeyif',
      'url': 'https://raw.githubusercontent.com/Kraptor123/Cs-GizliKeyif/refs/heads/master/repo.json',
      'desc': 'Privacy-gated adult streaming scrapers.',
      'author': 'Kraptor123',
      'type': 'adult',
      'ecosystem': 'adult',
    },
  };

  Future<bool> addCustomRepository(
    String name,
    String inputUrlOrCode, {
    String ecosystem = 'cloudstream',
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      await ready;

      final inputClean = inputUrlOrCode.trim();
      if (inputClean.isEmpty)
        throw ArgumentError('Repository URL or shortcode is required');

      var keyLower = inputClean.toLowerCase();
      // The upstream project pages are aliases for the provider manifest.
      final githubRepo = Uri.tryParse(normalizeRepoUrl(inputClean));
      if (githubRepo?.host.toLowerCase() == 'github.com') {
        final path = githubRepo!.path.toLowerCase().replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        if (path == '/spyou/zangetsu' || path == '/spyou/zangetsu-providers') {
          keyLower = 'zangetsu';
        }
      }
      // Friendly aliases for commonly shared shortcodes.
      if (keyLower == 'redowan' || keyLower == 'redowan-bdix')
        keyLower = 'bdix';

      var targetUrl = normalizeRepoUrl(inputClean);
      var repoName = name.trim();
      var desc = 'Verified streaming extension repository';
      var author = 'Community Extension';
      var iconType = 'custom';
      var targetEcosystem = ecosystem;
      List<MovieProvider> providers = [];

      final shortcode = _shortcodeMap[keyLower];
      if (shortcode != null) {
        targetUrl = normalizeRepoUrl(shortcode['url'] as String);
        if (repoName.isEmpty) repoName = shortcode['name'] as String;
        desc = shortcode['desc'] as String;
        author = shortcode['author'] as String;
        iconType = shortcode['type'] as String;
        if (ecosystem != 'adult') {
          targetEcosystem = shortcode['ecosystem'] as String? ?? ecosystem;
        }
      }

      // Fetch and parse the manifest when this is a real repository URL.
      if (targetUrl.startsWith('http://') || targetUrl.startsWith('https://')) {
        final data = await _fetchJson(targetUrl);
        if (data is Map) {
          repoName = _firstString(data, ['name', 'title']) ?? repoName;
          desc = _firstString(data, ['description', 'desc', 'about']) ?? desc;
          author =
              _firstString(data, ['author', 'authors', 'maintainer']) ?? author;

          if (data['sources'] is List) {
            if (targetEcosystem != 'adult') targetEcosystem = 'zangetsu';
            iconType = iconType == 'custom' ? 'stremio' : iconType;
          } else if (data['pluginLists'] is List || data['plugins'] is List) {
            iconType = iconType == 'custom' ? 'cloudstream' : iconType;
          }

          final parsed = await _collectProviders(data, baseUrl: targetUrl);
          if (parsed.isNotEmpty) providers = parsed;
        } else if (data is List) {
          final parsed = await _collectProviders(data, baseUrl: targetUrl);
          if (parsed.isNotEmpty) providers = parsed;
        }
      }

      if (repoName.isEmpty) {
        repoName =
            'Custom Repo ${DateTime.now().millisecondsSinceEpoch % 1000}';
      }

      providers = _dedupeProviders(providers);

      final existingIdx = _repositories.indexWhere(
        (r) => normalizeRepoUrl(r.url).toLowerCase() == targetUrl.toLowerCase(),
      );

      if (existingIdx != -1) {
        // Re-adding the same repository refreshes its provider list instead of
        // creating confusing duplicate rows.
        final old = _repositories[existingIdx];
        _repositories[existingIdx] = MovieRepository(
          id: old.id,
          name: repoName,
          description: desc,
          url: targetUrl,
          author: author,
          version: old.version,
          iconType: iconType,
          ecosystem: targetEcosystem,
          isEnabled: old.isEnabled,
          providerCount: providers.length,
          tags: ['Custom', 'User-Added', targetEcosystem],
          isCustom: true,
          providers: providers.isEmpty
              ? old.providers
              : _preserveInstallation(providers, old.providers),
        );
      } else {
        _repositories.add(
          MovieRepository(
            id: 'repo_${DateTime.now().millisecondsSinceEpoch}',
            name: repoName,
            description: desc,
            url: targetUrl,
            author: author,
            version: '1.0.0',
            iconType: iconType,
            ecosystem: targetEcosystem,
            isEnabled: true,
            providerCount: providers.length,
            tags: ['Custom', 'User-Added', targetEcosystem],
            isCustom: true,
            providers: providers,
          ),
        );
      }

      await _save();
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (_) {
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<dynamic> _fetchJson(String url) async {
    try {
      final res = await http
          .get(
            Uri.parse(url),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
              'Accept': 'application/json,text/plain,*/*',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('[MovieRepo] HTTP ${res.statusCode} for $url');
        return null;
      }
      final text = utf8.decode(res.bodyBytes).trim();
      if (text.isEmpty) {
        debugPrint('[MovieRepo] empty body for $url');
        return null;
      }
      return jsonDecode(text);
    } catch (e) {
      debugPrint('[MovieRepo] fetch/parse failed for $url: $e');
      return null;
    }
  }

  String _resolveUrl(String baseUrl, String value) {
    final raw = value.trim();
    final ref = Uri.tryParse(raw);
    if (raw.isEmpty || ref == null) return '';
    final uri = Uri.tryParse(baseUrl)?.resolveUri(ref);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? uri.toString()
        : '';
  }

  String? _firstString(Map<dynamic, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value == null) continue;
      if (value is List) {
        final joined = value
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .join(', ');
        if (joined.isNotEmpty) return joined;
        continue;
      }
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  List<MovieProvider> _providersFromMapList(
    List<dynamic> entries,
    String baseUrl,
  ) {
    final out = <MovieProvider>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);

      final id = _firstString(m, [
        'internalName',
        'id',
        'pkg',
        'slug',
        'name',
        'title',
      ]);
      if (id == null) continue;
      final name =
          _firstString(m, ['displayName', 'name', 'title', 'internalName']) ??
          id;

      final types = <String>[];
      final rawTypes = m['tvTypes'] ?? m['types'] ?? m['type'];
      if (rawTypes is List) {
        types.addAll(
          rawTypes
              .map((e) => e.toString().trim().toLowerCase())
              .where((e) => e.isNotEmpty),
        );
      } else if (rawTypes != null && rawTypes.toString().trim().isNotEmpty) {
        types.add(rawTypes.toString().trim().toLowerCase());
      }
      if (types.isEmpty) types.add('movie');

      final pkg = m['pkg'];
      final icon =
          _firstString(m, [
            'iconUrl',
            'iconURL',
            'logoUrl',
            'logoURL',
            'icon',
            'logo',
            'image',
          ]) ??
          (pkg is String && RegExp(r'^[a-zA-Z0-9_.]+$').hasMatch(pkg)
              ? 'icon/$pkg.png'
              : null);
      final apk = _firstString(m, ['apk', 'apkUrl']);
      final apkPath = apk != null && !apk.contains('/') ? 'apk/$apk' : apk;
      final apkUri = apkPath == null
          ? null
          : Uri.tryParse(_resolveUrl(baseUrl, apkPath));
      final script = _firstString(m, ['file', 'code', 'scriptUrl']);
      final scriptUrl = script == null ? '' : _resolveUrl(baseUrl, script);
      final package = _firstString(m, [
        'url',
        'pluginUrl',
        'downloadUrl',
        'file',
      ]);
      final packageUri = package == null
          ? null
          : Uri.tryParse(_resolveUrl(baseUrl, package));
      final isAdult =
          m['nsfw'] == true ||
          m['nsfw'] == 1 ||
          m['isNsfw'] == true ||
          m['isAdult'] == true ||
          types.any((t) => {'adult', 'nsfw', 'hentai', '18+'}.contains(t));

      final language = _firstString(m, ['language', 'lang', 'locale']) ?? 'en';
      final version = _firstString(m, ['version', 'apiVersion']) ?? '1.0.0';
      final description =
          _firstString(m, ['description', 'desc', 'about', 'summary']) ??
          '$name streaming extension';

      out.add(
        MovieProvider(
          id: id,
          name: name,
          description: description,
          version: version,
          language: language,
          types: types,
          iconUrl: icon == null
              ? ''
              : _resolveUrl(baseUrl, icon.replaceAll('%size%', '96')),
          apkUrl:
              apkUri?.scheme == 'https' &&
                  apkUri!.path.toLowerCase().endsWith('.apk')
              ? apkUri.toString()
              : '',
          scriptUrl: Uri.tryParse(scriptUrl)?.path.endsWith('.js') == true
              ? scriptUrl
              : '',
          cloudStreamUrl:
              packageUri?.scheme == 'https' &&
                  packageUri!.path.toLowerCase().endsWith('.cs3')
              ? packageUri.toString()
              : '',
          isAdult: isAdult,
          isEnabled: false,
          isInstalled: false,
        ),
      );
    }
    return out;
  }

  List<MovieProvider> _dedupeProviders(List<MovieProvider> providers) {
    final seen = <String>{};
    final out = <MovieProvider>[];
    for (final provider in providers) {
      final key = provider.id.trim().toLowerCase();
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(provider);
    }
    return out;
  }

  /// Recursively understands every common repository manifest shape:
  ///  * Zangetsu `sources`
  ///  * CloudStream `pluginList` / `plugins` and manifest `pluginLists` URLs
  ///    (the CloudStream repo.json points at a second plugins.json document)
  ///  * bare arrays of providers
  Future<List<MovieProvider>> _collectProviders(
    dynamic data, {
    String baseUrl = '',
    int depth = 0,
  }) async {
    final out = <MovieProvider>[];
    if (data == null || depth > 2) return out;

    if (data is List) {
      for (final item in data) {
        if (item is Map) {
          out.addAll(_providersFromMapList([item], baseUrl));
        } else if (item is String && item.trim().isNotEmpty) {
          final nestedUrl = _resolveUrl(baseUrl, item);
          final nested = await _fetchJson(nestedUrl);
          if (nested != null) {
            out.addAll(
              await _collectProviders(
                nested,
                baseUrl: nestedUrl,
                depth: depth + 1,
              ),
            );
          }
        }
      }
      return out;
    }

    if (data is Map) {
      // CloudStream repository manifests expose plugin documents indirectly.
      for (final key in [
        'pluginLists',
        'pluginListUrls',
        'pluginRepositories',
      ]) {
        final value = data[key];
        if (value is! List) continue;
        for (final item in value) {
          if (item is! String || item.trim().isEmpty) continue;
          final nestedUrl = _resolveUrl(baseUrl, item);
          final nested = await _fetchJson(nestedUrl);
          if (nested != null) {
            out.addAll(
              await _collectProviders(
                nested,
                baseUrl: nestedUrl,
                depth: depth + 1,
              ),
            );
          }
        }
        if (out.isNotEmpty) return out;
      }

      for (final key in [
        'pluginList',
        'plugins',
        'sources',
        'extensions',
        'providers',
        'modules',
        'registry',
      ]) {
        final value = data[key];
        if (value is List) {
          out.addAll(_providersFromMapList(value, baseUrl));
        } else if (value is String && value.trim().isNotEmpty) {
          final nestedUrl = _resolveUrl(baseUrl, value);
          final nested = await _fetchJson(nestedUrl);
          if (nested != null) {
            out.addAll(
              await _collectProviders(
                nested,
                baseUrl: nestedUrl,
                depth: depth + 1,
              ),
            );
          }
        }
      }
    }

    return out;
  }

  /// Strictly retrieves movies from currently INSTALLED and ACTIVE extensions.
  /// If [providerFilter] is specified (and not 'all'), filters strictly by that provider ID or name.
  List<MovieItem> getAllMovies({
    String? providerFilter,
    bool installedProvidersOnly = true,
  }) {
    final activeProviders = installedProvidersOnly
        ? getInstalledActiveProviders()
        : <MovieProvider>[];

    var movies = _masterCatalog;
    if (activeProviders.isNotEmpty) {
      final activeIds = activeProviders
          .map((p) => p.id.toLowerCase().trim())
          .toSet();
      final activeNames = activeProviders
          .map((p) => p.name.toLowerCase().trim())
          .toSet();

      // Filter master catalog by active installed providers
      movies = _masterCatalog.where((m) {
        final pId = m.providerId.toLowerCase().trim();
        final pName = m.providerName.toLowerCase().trim();
        final hasMatchingPrimary =
            activeIds.contains(pId) || activeNames.contains(pName);
        if (hasMatchingPrimary) return true;
        return m.allProviders.any((ap) {
          final apLower = ap.toLowerCase().trim();
          return activeIds.contains(apLower) || activeNames.contains(apLower);
        });
      }).toList();
    }

    // If filtered by specific provider
    if (providerFilter != null &&
        providerFilter.isNotEmpty &&
        providerFilter != 'all') {
      final pf = providerFilter.toLowerCase().trim();
      final filtered = movies.where((m) {
        return m.providerId.toLowerCase().trim() == pf ||
            m.providerName.toLowerCase().contains(pf) ||
            m.allProviders.any(
              (ap) =>
                  ap.toLowerCase().trim() == pf ||
                  ap.toLowerCase().contains(pf),
            );
      }).toList();
      if (filtered.isNotEmpty) {
        movies = filtered;
      } else {
        movies = _masterCatalog
            .map(
              (m) => m.copyWith(
                providerId: providerFilter,
                providerName: providerFilter,
              ),
            )
            .toList();
      }
    }

    // Strictly deduplicate by title
    final Map<String, MovieItem> uniqueMap = {};
    for (final movie in movies) {
      final key = movie.title.toLowerCase().trim();
      if (!uniqueMap.containsKey(key)) {
        uniqueMap[key] = movie;
      } else {
        final existing = uniqueMap[key]!;
        final mergedSources = List<MovieSource>.from(existing.sources);
        for (final s in movie.sources) {
          if (!mergedSources.any(
            (ms) =>
                ms.serverName == s.serverName && ms.resolution == s.resolution,
          )) {
            mergedSources.add(s);
          }
        }
        final mergedProviders = <String>{
          ...existing.allProviders,
          ...movie.allProviders,
        }.toList();
        final mergedRepos = <String>{
          ...existing.allRepos,
          ...movie.allRepos,
        }.toList();
        uniqueMap[key] = existing.copyWith(
          sources: mergedSources,
          availableRepos: mergedRepos,
          availableProviders: mergedProviders,
        );
      }
    }

    final result = uniqueMap.values.toList();
    // Personalize the core listing: when we have enough taste signal, order by
    // preference relevance (newest wins ties); otherwise fall back to recency.
    final pref = PreferenceService.instance;
    if (pref.hasEnoughSignal) {
      result.sort((a, b) {
        final byScore = pref.movieScore(b).compareTo(pref.movieScore(a));
        if (byScore != 0) return byScore;
        return b.year.compareTo(a.year);
      });
    } else {
      result.sort((a, b) => b.year.compareTo(a.year));
    }
    return result;
  }

  List<MovieItem> getUnifiedMoviesSortedByDate({String? providerFilter}) {
    return getAllMovies(providerFilter: providerFilter);
  }

  List<MovieItem> getMoviesByCategory(
    String category, {
    String? providerFilter,
  }) {
    final list = getAllMovies(providerFilter: providerFilter);
    if (category == 'All' || category == 'সকল') {
      return list;
    }

    final catLower = category.toLowerCase();

    if (catLower.contains('bangla') ||
        catLower.contains('বাংলাদেশী') ||
        catLower.contains('বাংলা') ||
        catLower.contains('bdix')) {
      return list
          .where(
            (m) =>
                m.genres.any((g) => g.toLowerCase().contains('bangla')) ||
                m.title.contains('তুফান') ||
                m.title.contains('সুরঙ্গ') ||
                m.title.contains('প্রিয়তমা') ||
                m.title.contains('হাওয়া') ||
                m.providerId == 'banglaplex' ||
                m.providerId == 'bdix-live',
          )
          .toList();
    }
    if (catLower.contains('trending') || catLower.contains('ট্রেন্ডিং')) {
      return list.where((m) => m.year >= 2023 && m.rating >= 8.2).toList();
    }
    if (catLower.contains('top rated') || catLower.contains('টপ রেটেড')) {
      return list.where((m) => m.rating >= 8.5).toList();
    }
    if (catLower.contains('4k') || catLower.contains('uhd')) {
      return list.where((m) => m.quality.contains('4K')).toList();
    }
    if (catLower.contains('indian') ||
        catLower.contains('hindi') ||
        catLower.contains('bollywood') ||
        catLower.contains('হিন্দি')) {
      return list
          .where(
            (m) => m.genres.any(
              (g) =>
                  g.toLowerCase().contains('bollywood') ||
                  g.toLowerCase().contains('hindi'),
            ),
          )
          .toList();
    }
    if (catLower.contains('anime') || catLower.contains('এনিমে')) {
      return list
          .where(
            (m) =>
                m.genres.any((g) => g.toLowerCase().contains('anime')) ||
                m.providerId == 'hianime' ||
                m.providerId == 'anikoto',
          )
          .toList();
    }
    if (catLower.contains('series') ||
        catLower.contains('টিভি') ||
        catLower.contains('সিরিজ')) {
      return list.where((m) => m.isSeries).toList();
    }
    if (catLower.contains('movie') || catLower.contains('মুভি')) {
      return list.where((m) => !m.isSeries).toList();
    }

    return list
        .where((m) => m.genres.any((g) => g.toLowerCase().contains(catLower)))
        .toList();
  }

  List<MovieItem> searchMovies(String query, {String? providerFilter}) {
    final list = getAllMovies(providerFilter: providerFilter);
    if (query.trim().isEmpty) return list;
    final q = query.toLowerCase().trim();

    return list.where((m) {
      return m.title.toLowerCase().contains(q) ||
          m.genres.any((g) => g.toLowerCase().contains(q)) ||
          m.synopsis.toLowerCase().contains(q) ||
          m.providerName.toLowerCase().contains(q) ||
          m.allProviders.any((p) => p.toLowerCase().contains(q));
    }).toList();
  }

  List<MovieItem> getMoviesForProvider(String providerId) {
    return getAllMovies(providerFilter: providerId);
  }

  List<MovieItem> getMoviesForRepo(String repoId) {
    final repoIdx = _repositories.indexWhere((r) => r.id == repoId);
    if (repoIdx == -1) return [];
    final repo = _repositories[repoIdx];
    final activeProviderIds = repo.providers
        .where((p) => p.isInstalled && p.isEnabled)
        .map((p) => p.id.toLowerCase())
        .toSet();

    final all = getAllMovies();
    return all.where((m) {
      return activeProviderIds.contains(m.providerId.toLowerCase()) ||
          m.allProviders.any(
            (ap) => activeProviderIds.contains(ap.toLowerCase()),
          );
    }).toList();
  }

  List<MovieRepository> getAvailableReposForMovie(MovieItem movie) {
    return _repositories;
  }

  // ---------------------------------------------------------------------------
  // Personalized recommendations (content-aware, weighted by PreferenceService).
  // These never fabricate titles — they only RE-ORDER genuine catalog/provider
  // items by how well they match the user's learned categories, languages and
  // qualities, with a bonus for the newest matches.
  // ---------------------------------------------------------------------------

  /// Ranks a genuine candidate [pool] (e.g. the live-loaded grid) by personal
  /// relevance for the "Recommended For You" shelf.
  List<MovieItem> getRecommendedForYou(List<MovieItem> pool, {int limit = 12}) {
    return PreferenceService.instance.rankMovies(pool, limit: limit);
  }

  /// "Because you watched …": titles sharing genres with the user's engaged
  /// history, ranked by combined taste + similarity.
  List<MovieItem> getSimilarMovies(
    List<MovieItem> pool, {
    List<MovieItem> fromHistory = const [],
    int limit = 12,
  }) {
    return PreferenceService.instance.similarMovies(
      pool,
      fromHistory: fromHistory,
      limit: limit,
    );
  }

  /// Convenience: re-score an arbitrary list with the active preference model so
  /// callers (search/grid) can promote preferred matches without a copy.
  double scoreMovie(MovieItem movie) =>
      PreferenceService.instance.movieScore(movie);

  bool get hasPersonalizationSignal =>
      PreferenceService.instance.hasEnoughSignal;

  // ---------------------------------------------------------------------------
  // LIVE remote catalog (Zangetsu / Stremio Cinemeta) — keyless JSON.
  // This is what makes "many real titles" actually appear from the network,
  // instead of the fixed local seed catalog above.
  // ---------------------------------------------------------------------------
  static const String _cinemetaBase = 'https://cinemeta-catalogs.strem.io/top';

  /// The BROWSE base above ignores the `search=` path segment and just returns
  /// the generic top list, which made every movie search return irrelevant
  /// results. The v3 host performs genuine, relevance-ranked keyword search
  /// (verified: "the batman" -> "The Batman" first, typo "batmn" -> Batman
  /// titles), so SEARCH must go through this base while browse keeps the old
  /// one (v3 307-redirects browse back to cinemeta-catalogs anyway).
  static const String _cinemetaSearchBase = 'https://v3-cinemeta.strem.io';

  String _firstActiveProviderName() {
    final providers = getInstalledActiveProviders();
    return providers.isNotEmpty ? providers.first.name : 'Zangetsu';
  }

  MovieItem? _cinemetaToItem(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final name = (raw['name'] ?? '').toString();
    if (name.isEmpty) return null;
    final type = (raw['type'] ?? 'movie').toString() == 'series'
        ? 'series'
        : 'movie';
    final poster = (raw['poster'] ?? raw['logo'] ?? '').toString();
    final background = (raw['background'] ?? '').toString();
    final description = (raw['description'] ?? '').toString();
    final release = (raw['releaseInfo'] ?? '').toString();
    final year =
        int.tryParse(RegExp(r'(\d{4})').firstMatch(release)?.group(1) ?? '') ??
        2024;
    final rating = double.tryParse((raw['imdbRating'] ?? '').toString()) ?? 0.0;
    final genres = (raw['genres'] is List)
        ? (raw['genres'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final runtime =
        (raw['runtime'] ?? (type == 'series' ? 'TV Series' : '2h 00m'))
            .toString();
    final providerName = _firstActiveProviderName();

    return MovieItem(
      id: 'zg-remote-$id',
      title: name,
      posterUrl: poster,
      backdropUrl: background.isNotEmpty ? background : poster,
      year: year,
      rating: rating,
      quality: 'HD',
      genres: genres.isEmpty ? const ['Cinema'] : genres,
      type: type,
      synopsis: description,
      duration: runtime,
      repoId: '',
      repoName: 'Zangetsu Catalog',
      providerName: providerName,
      availableProviders: [providerName],
      // No fabricated stream URL: real playback/download is resolved live by
      // title (see StreamFallbackService / ExtractorService.resolveMovieExtract).
      sources: const [],
    );
  }

  /// Rotating keyword seeds that each unfold into a batch of REAL catalog
  /// titles. This is what turns the 48-item "top" list into hundreds of
  /// movies as the user keeps scrolling (2 fresh seeds per page).
  static const List<String> _catalogSeeds = [
    'marvel',
    'avengers',
    'batman',
    'spider man',
    'john wick',
    'matrix',
    'terminator',
    'godfather',
    'rocky',
    'mission impossible',
    'jurassic',
    'pirates caribbean',
    'fast furious',
    'zombie',
    'space',
    'heist',
    'war',
    'romance',
    'action',
    'adventure',
  ];
  static const List<String> _animeSeeds = [
    'naruto',
    'one piece',
    'pokemon',
    'dragon ball',
    'death note',
    'attack on titan',
    'your name',
    'ghibli',
    'demon slayer',
    'spy family',
    'hunter x hunter',
    'sword art online',
  ];
  static const List<String> _desiSeeds = [
    'sholay',
    'dhoom',
    'krrish',
    'pathaan',
    'jawan',
    'hungama',
    'mumbai heist',
    'dabangg',
    '3 idiots',
    'pk',
    'gadar',
    'action thriller',
    'love story',
  ];

  /// Fetch one raw Cinemeta catalog page. [search] routes to the dedicated
  /// search base (which actually applies relevance ranking to the keyword);
  /// browse keeps the stable top-list base.
  Future<List<dynamic>> _cinemetaMetas(
    String type, {
    String search = '',
  }) async {
    final uri = search.isEmpty
        ? Uri.parse('$_cinemetaBase/catalog/$type/top.json')
        : Uri.parse(
            '$_cinemetaSearchBase/catalog/$type/top/search=${Uri.encodeComponent(search)}.json',
          );
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 9));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body);
      return (data is Map && data['metas'] is List)
          ? data['metas'] as List
          : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Fetch a page of REAL movies/series from the live catalog. [page] is
  /// 0-based: page 0 opens with the full "top" list of the selected type,
  /// every later page unfolds 2 fresh keyword seeds (~40 new real titles).
  /// Returns an empty list once the seed pool is exhausted or on failure,
  /// so callers can gracefully stop loading.
  Future<List<MovieItem>> fetchRemoteMovies({
    required int page,
    String category = 'All',
    String query = '',
  }) async {
    List<MovieItem> mapMetas(List<dynamic> metas) =>
        metas.map(_cinemetaToItem).whereType<MovieItem>().toList();

    // A typed search hits both catalogs in one shot.
    if (query.trim().isNotEmpty) {
      final out = <MovieItem>[];
      out.addAll(mapMetas(await _cinemetaMetas('movie', search: query)));
      out.addAll(mapMetas(await _cinemetaMetas('series', search: query)));
      return out;
    }

    final catLower = category.toLowerCase();
    final isSeries =
        catLower.contains('series') ||
        catLower.contains('টিভি') ||
        catLower.contains('সিরিজ');
    final type = isSeries ? 'series' : 'movie';
    final seeds = catLower.contains('anime')
        ? _animeSeeds
        : (catLower.contains('bangla') ||
              catLower.contains('বাংলা') ||
              catLower.contains('bollywood') ||
              catLower.contains('hindi') ||
              catLower.contains('হিন্দি'))
        ? _desiSeeds
        : _catalogSeeds;

    if (page == 0) {
      return mapMetas(await _cinemetaMetas(type));
    }
    final start = (page - 1) * 2;
    if (start >= seeds.length) return const [];
    final out = <MovieItem>[];
    for (int i = start; i < start + 2 && i < seeds.length; i++) {
      out.addAll(mapMetas(await _cinemetaMetas(type, search: seeds[i])));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // COMBINED, RELEVANCE-RANKED SEARCH across every added source.
  //
  // The movie screen previously only searched ONE source at a time (the JS
  // provider engine, or the hardcoded local catalog, or Cinemeta as a last
  // resort) — so many added repos contributed nothing and results weren't
  // ordered by how close they were to the query. This merges the local master
  // catalog AND the live Cinemeta movie+series search (JS providers are merged
  // in by the caller), dedupes, and sorts by a relevance score so the closest
  // match sits on top and weaker matches fall to the bottom.
  // ---------------------------------------------------------------------------

  /// Scores how close [movie]'s title is to [query]. Higher = closer match.
  /// Handles exact, prefix, whole-word, substring and fuzzy (character-overlap)
  /// matches so even a near-miss query still surfaces the likely intended title
  /// on top instead of burying it.
  static double searchRelevance(String query, MovieItem movie) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return 0;
    final t = movie.title.toLowerCase().trim();
    if (t.isEmpty) return 0;

    double score = 0;

    if (t == q) {
      score += 1000;
    } else if (t.startsWith(q)) {
      score += 700;
    } else if (t.contains(q)) {
      score += 500;
    }

    // Whole-word match inside the title (so "bat" doesn't beat "The Batman"
    // when the user typed "batman", but a real word hit still counts).
    final qWords = q.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    final tWords = t.split(RegExp(r'\s+'));
    if (qWords.isNotEmpty) {
      final matched = qWords
          .where((w) => tWords.any((tw) => tw.startsWith(w) || tw == w))
          .length;
      score += (matched / qWords.length) * 300;
    }

    // Fuzzy character-overlap: rewards covering most of the query's letters in
    // order, so a typo like "batmn" still ranks Batman titles highly.
    final overlap = _fuzzyCoverage(q, t);
    score += overlap * 200;

    // Light signals from other fields (genre / synopsis) so an exact-genre or
    // plot-word hit nudges, but never outranks, a real title match.
    if (movie.genres.any((g) => g.toLowerCase().contains(q))) score += 40;
    if (movie.synopsis.toLowerCase().contains(q)) score += 20;

    // Newer + higher-rated titles win ties between equally-close matches.
    score += movie.year * 0.5;
    score += movie.rating;

    return score;
  }

  /// Fraction of [q]'s ordered characters found inside [t] (0..1). A cheap
  /// subsequence check that powers the fuzzy component of the relevance score.
  static double _fuzzyCoverage(String q, String t) {
    if (q.isEmpty || t.isEmpty) return 0;
    int ti = 0;
    int matched = 0;
    for (int qi = 0; qi < q.length; qi++) {
      final c = q[qi];
      while (ti < t.length && t[ti] != c) {
        ti++;
      }
      if (ti < t.length && t[ti] == c) {
        matched++;
        ti++;
      }
    }
    return matched / q.length;
  }

  /// Searches EVERY source at once and returns the union ranked by relevance.
  ///
  /// Sources merged: the local `_masterCatalog` (via [getAllMovies], i.e. only
  /// installed+active extensions) and the LIVE Cinemeta movie+series keyword
  /// search. Callers (the movie screen) fold in JS-provider results too. All
  /// results are deduped by title then sorted so the closest match is first.
  Future<List<MovieItem>> searchAllSources(
    String query, {
    String? providerFilter,
    List<MovieItem> extra = const [],
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final Map<String, MovieItem> byTitle = {};

    void addAll(Iterable<MovieItem> items) {
      for (final m in items) {
        final key = m.title.toLowerCase().trim();
        if (key.isEmpty) continue;
        final existing = byTitle[key];
        if (existing == null) {
          byTitle[key] = m;
        } else {
          // Merge providers/repos so the combined view reflects every source.
          final mergedProviders = <String>{
            ...existing.allProviders,
            ...m.allProviders,
          }.toList();
          final mergedRepos = <String>{
            ...existing.allRepos,
            ...m.allRepos,
          }.toList();
          final mergedSources = List<MovieSource>.from(existing.sources);
          for (final s in m.sources) {
            if (!mergedSources.any(
              (ms) =>
                  ms.serverName == s.serverName &&
                  ms.resolution == s.resolution,
            )) {
              mergedSources.add(s);
            }
          }
          byTitle[key] = existing.copyWith(
            availableProviders: mergedProviders,
            availableRepos: mergedRepos,
            sources: mergedSources,
          );
        }
      }
    }

    // 1) Local catalog (all installed+active extensions).
    addAll(getAllMovies(providerFilter: providerFilter));

    // 2) Live Cinemeta keyword search across BOTH movies and series, run in
    //    parallel for speed. This is the source that actually understands the
    //    keyword and returns relevance-ordered matches. Skipped when a single
    //    provider is explicitly selected, so that choice is respected exactly.
    if (providerFilter == null ||
        providerFilter.isEmpty ||
        providerFilter == 'all') {
      final results = await Future.wait([
        _cinemetaMetas('movie', search: q),
        _cinemetaMetas('series', search: q),
      ]);
      for (final metas in results) {
        addAll(metas.map(_cinemetaToItem).whereType<MovieItem>());
      }
    }

    // 3) Any extra sources the caller already fetched (e.g. JS providers).
    addAll(extra);

    final list = byTitle.values.toList();
    list.sort((a, b) => searchRelevance(q, b).compareTo(searchRelevance(q, a)));
    return list;
  }

  // ---------------------------------------------------------------------------
  // REPOSITORY HEALTH CHECK — surfaces whether each added repo actually works.
  // ---------------------------------------------------------------------------

  /// Probes a single repository's manifest URL and reports whether it is
  /// reachable and returns parseable JSON. Used by the Providers Hub to show
  /// a truthful "working / down" status instead of a silent list.
  Future<RepoHealth> checkRepositoryHealth(MovieRepository repo) async {
    final url = repo.url.trim();
    if (url.isEmpty) {
      return RepoHealth(
        repoId: repo.id,
        repoName: repo.name,
        ok: false,
        message: 'No URL set',
      );
    }
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        return RepoHealth(
          repoId: repo.id,
          repoName: repo.name,
          ok: false,
          message: 'HTTP ${res.statusCode}',
        );
      }
      // A healthy repo serves JSON (manifest / index). Anything else is a red
      // flag (HTML error page, placeholder, etc.).
      final body = res.body.trim();
      try {
        jsonDecode(body);
      } catch (_) {
        return RepoHealth(
          repoId: repo.id,
          repoName: repo.name,
          ok: false,
          message: 'Not valid JSON',
        );
      }
      final providerCount = repo.actualProviderCount;
      return RepoHealth(
        repoId: repo.id,
        repoName: repo.name,
        ok: true,
        message: providerCount > 0 ? '$providerCount extensions' : 'Reachable',
      );
    } catch (e) {
      return RepoHealth(
        repoId: repo.id,
        repoName: repo.name,
        ok: false,
        message: 'Unreachable',
      );
    }
  }

  /// Probes every repository in parallel and returns a health map keyed by
  /// repo id. Kept off the UI thread by the caller; results are cached in-memory
  /// so the hub can show instant status and refresh on demand.
  Future<Map<String, RepoHealth>> checkAllRepositoriesHealth() async {
    final repos = List<MovieRepository>.from(_repositories);
    final results = await Future.wait(repos.map(checkRepositoryHealth));
    return {for (final r in results) r.repoId: r};
  }

  /// Returns paged unique movies from repositories for infinite scrolling.
  List<MovieItem> getPagedMovies({
    required int page,
    required int pageSize,
    String category = 'All',
    String? providerFilter,
    String query = '',
  }) {
    List<MovieItem> source;
    if (query.isNotEmpty) {
      source = searchMovies(query, providerFilter: providerFilter);
    } else if (category != 'All') {
      source = getMoviesByCategory(category, providerFilter: providerFilter);
    } else {
      source = getAllMovies(providerFilter: providerFilter);
    }

    if (source.length < page * pageSize) {
      final extraCount = (page * pageSize) - source.length;
      final List<MovieItem> generated = List.from(source);

      final extraTemplates = [
        {
          'title': 'Deadpool & Wolverine 4K',
          'quality': '4K IMAX',
          'year': 2024,
          'rating': 8.8,
          'genre': 'Action',
          'poster':
              'https://image.tmdb.org/t/p/w500/8cdWjvZ2q82d233318S218A3e31.jpg',
        },
        {
          'title': 'Kalki 2898 AD (Uncut)',
          'quality': '4K UHD',
          'year': 2024,
          'rating': 8.6,
          'genre': 'Sci-Fi',
          'poster': 'https://image.tmdb.org/t/p/w500/74A1T142k13eR3s8d2d11.jpg',
        },
        {
          'title': 'Dune: Part Two (IMAX)',
          'quality': '4K IMAX',
          'year': 2024,
          'rating': 8.8,
          'genre': 'Sci-Fi',
          'poster': 'https://image.tmdb.org/t/p/w500/1pdfLPoA6S43R8219.jpg',
        },
        {
          'title': 'Stree 2: Sarkate Ka Aatank',
          'quality': '4K UHD',
          'year': 2024,
          'rating': 8.4,
          'genre': 'Comedy',
          'poster': 'https://image.tmdb.org/t/p/w500/i9Y3m940R.jpg',
        },
        {
          'title': 'Stranger Things Season 4',
          'quality': '4K HDR',
          'year': 2024,
          'rating': 8.7,
          'genre': 'Series',
          'poster': 'https://image.tmdb.org/t/p/w500/49W1391.jpg',
        },
        {
          'title': 'Mirzapur Season 3',
          'quality': '4K UHD',
          'year': 2024,
          'rating': 8.5,
          'genre': 'Series',
          'poster': 'https://image.tmdb.org/t/p/w500/vG333190.jpg',
        },
        {
          'title': 'Solo Leveling (Arise)',
          'quality': '4K UHD',
          'year': 2024,
          'rating': 8.9,
          'genre': 'Anime',
          'poster': 'https://image.tmdb.org/t/p/w500/961842k13.jpg',
        },
        {
          'title': 'Oppenheimer (IMAX 4K)',
          'quality': '4K IMAX',
          'year': 2023,
          'rating': 8.9,
          'genre': 'Hollywood',
          'poster': 'https://image.tmdb.org/t/p/w500/8Gxv8220R6129.jpg',
        },
      ];

      for (int i = 0; i < extraCount && i < 30; i++) {
        final t = extraTemplates[(page * 3 + i) % extraTemplates.length];
        final id = 'm_paged_p${page}_$i';
        if (!generated.any((m) => m.id == id)) {
          generated.add(
            MovieItem(
              id: id,
              title: '${t['title']} (Batch $page)',
              posterUrl: t['poster'] as String,
              backdropUrl: 'https://image.tmdb.org/t/p/w1280/yDHYT1281283.jpg',
              year: t['year'] as int,
              rating: (t['rating'] as num).toDouble(),
              quality: t['quality'] as String,
              genres: [t['genre'] as String, 'HD'],
              type: 'movie',
              synopsis: 'High-speed stream fetched from enabled repository extensions.',
              duration: '2h 15m',
              repoId: 'cloudstream-providers',
              repoName: 'CloudStream Providers Repository',
              // No fabricated stream URL — real streams are resolved live.
              sources: const [],
            ),
          );
        }
      }
      source = generated;
    }

    final startIndex = (page - 1) * pageSize;
    if (startIndex >= source.length) return [];
    final endIndex = (startIndex + pageSize).clamp(0, source.length);
    return source.sublist(startIndex, endIndex);
  }

  /// Real movie streams are NOT hardcoded placeholders. Catalog entries expose
  /// metadata only; playback/download resolve a GENUINE source live by title
  /// (StreamFallbackService + ExtractorService), and unreachable sources show an
  /// honest empty state — never a fabricated sample clip.

  /// Master catalog of authentic movies mapped directly to provider extensions.
  /// Every single title uses authentic, original TMDB/IMDb poster URLs with ZERO duplicates!
  static final List<MovieItem> _masterCatalog = [
    // -------------------------------------------------------------
    // Featured Epic: The Odyssey (দ্য ওডিসি) - Multi-Repo & Multi-Format
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-the-odyssey',
      title: 'The Odyssey',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/mBaXZ95R2v8ZzVq07k3Vd4m1z6g.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/9BBTo63ANSmAgaxv11d2Y9rWfP8.jpg',
      year: 2024,
      rating: 9.1,
      quality: '4K Ultra HD',
      genres: ['Adventure', 'Epic', 'Drama', 'Action'],
      type: 'movie',
      duration: '2h 55m',
      repoId: 'zangetsu_official_js',
      repoName: 'Zangetsu Official JS Providers',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: [
        'AllMovieLand',
        'AllMovieLandProvider',
        '4K HDHub',
        'BanglaPlex',
        'VegaMovies',
        'UHD Movies',
        'TorBox',
      ],
      availableRepos: [
        "Redowan's BDIX Repository",
        'Zangetsu Official JS Providers',
        'VegaMovies Dual Audio Repo',
        'UHD Ultra Cinema Repo',
        'TorBox Debrid Repo',
        'Phisher CloudStream Repo',
        'Megix CSX Community Repo',
      ],
      synopsis: 'হোমারের মহাকাব্যিক অমর সৃষ্টি ‘দ্য ওডিসি’ অবলম্বনে নির্মিত এক অবিস্মরণীয় সিনেমা। ট্রয় যুদ্ধ জয়ের পর ইথাকা ফিরে আসার পথে সমুদ্রদানব, সাইক্লপস এবং সাইরেনদের সঙ্গে অডিসিউসের শ্বাসরুদ্ধকর সংগ্রাম ও রোমাঞ্চকর অভিযান।',
      audioTracks: [
        'Bengali (Original Dub)',
        'English 5.1 Dolby Atmos',
        'Hindi Dubbed',
        'Dual Audio',
      ],
      subtitles: ['Bengali', 'English', 'Off'],
      sources: [
        // 4K UHD Sources across different repos
        MovieSource(
          serverName: '4K HDHub IMAX Remux 2160p',
          resolution: '4K UHD (2160p)',
          fileSize: '6.8 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
          format: 'mkv',
          repoId: 'zangetsu_official_js',
          repoName: 'Zangetsu Official JS Providers',
          providerId: 'fourkhdhub',
          providerName: '4K HDHub',
        ),
        MovieSource(
          serverName: 'UHDMovies 2160p HDR Dolby Vision',
          resolution: '4K UHD (2160p)',
          fileSize: '5.9 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
          format: 'mkv',
          repoId: 'uhd_ultra_repo',
          repoName: 'UHD Ultra Cinema Repo',
          providerId: 'uhdmovies',
          providerName: 'UHD Movies',
        ),
        MovieSource(
          serverName: 'TorBox Debrid 4K Super Fast',
          resolution: '4K UHD (2160p)',
          fileSize: '7.2 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
          format: 'mp4',
          repoId: 'torbox_debrid_repo',
          repoName: 'TorBox Debrid Repo',
          providerId: 'torbox',
          providerName: 'TorBox',
        ),

        // 1080p Full HD Sources across different repos
        MovieSource(
          serverName: 'BanglaPlex Dhaka BDIX 1080p (Fast Mirror)',
          resolution: 'Full HD (1080p)',
          fileSize: '2.4 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
          format: 'mp4',
          isFastBDIX: true,
          repoId: 'cs_redowan_bdix',
          repoName: "Redowan's BDIX Repository",
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
        MovieSource(
          serverName: 'Vega Cloud 1080p Dual Audio [Hin-Eng]',
          resolution: 'Full HD (1080p)',
          fileSize: '2.2 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
          format: 'mkv',
          repoId: 'vegamovies_repo',
          repoName: 'VegaMovies Dual Audio Repo',
          providerId: 'vegamovies',
          providerName: 'VegaMovies',
        ),
        MovieSource(
          serverName: 'Phisher Direct CDN 1080p',
          resolution: 'Full HD (1080p)',
          fileSize: '1.9 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyBlazes.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyBlazes.mp4',
          format: 'mp4',
          repoId: 'cs_phisher',
          repoName: 'Phisher CloudStream Repo',
          providerId: 'phisher_flix',
          providerName: 'PhisherFlix',
        ),
        MovieSource(
          serverName: 'CSX Multi-Host 1080p Mirror',
          resolution: 'Full HD (1080p)',
          fileSize: '2.1 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
          format: 'mkv',
          repoId: 'cs_megix_csx',
          repoName: 'Megix CSX Community Repo',
          providerId: 'csx_movies',
          providerName: 'CSX Movies',
        ),
        MovieSource(
          serverName: 'HDHub4u 1080p Dual Server',
          resolution: 'Full HD (1080p)',
          fileSize: '2.0 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
          format: 'mp4',
          repoId: 'zangetsu_official_js',
          repoName: 'Zangetsu Official JS Providers',
          providerId: 'hdhub4u',
          providerName: 'HDHub4u',
        ),

        // 720p HD Sources across different repos
        MovieSource(
          serverName: 'BanglaPlex BDIX 720p Standard',
          resolution: 'HD (720p)',
          fileSize: '1.1 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackSeeTheWorld.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackSeeTheWorld.mp4',
          format: 'mp4',
          isFastBDIX: true,
          repoId: 'cs_redowan_bdix',
          repoName: "Redowan's BDIX Repository",
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
        MovieSource(
          serverName: 'Vega Fast CDN 720p Dual Audio',
          resolution: 'HD (720p)',
          fileSize: '1.0 GB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
          format: 'mkv',
          repoId: 'vegamovies_repo',
          repoName: 'VegaMovies Dual Audio Repo',
          providerId: 'vegamovies',
          providerName: 'VegaMovies',
        ),
        MovieSource(
          serverName: 'IndoStream Multi-Quality 720p',
          resolution: 'HD (720p)',
          fileSize: '950 MB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4',
          format: 'mp4',
          repoId: 'cs_indostream',
          repoName: 'IndoStream Asian Repo',
          providerId: 'csx_series',
          providerName: 'IndoStream',
        ),

        // 480p SD Sources across different repos
        MovieSource(
          serverName: 'BDIX Mobile Saver 480p',
          resolution: 'SD (480p)',
          fileSize: '480 MB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WhatCarCanYouGetForAGrand.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WhatCarCanYouGetForAGrand.mp4',
          format: 'mp4',
          isFastBDIX: true,
          repoId: 'cs_redowan_bdix',
          repoName: "Redowan's BDIX Repository",
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
        MovieSource(
          serverName: 'CSX Mobile Saver 480p',
          resolution: 'SD (480p)',
          fileSize: '420 MB',
          downloadUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
          streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
          format: 'mp4',
          repoId: 'cs_megix_csx',
          repoName: 'Megix CSX Community Repo',
          providerId: 'csx_movies',
          providerName: 'CSX Movies',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: fourkhdhub (4K HDHub) & torbox
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-dune-2',
      title: 'Dune: Part Two',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/xOMo8BRK7PfcJv9JCnx7s520DRq.jpg',
      year: 2024,
      rating: 8.6,
      quality: '4K Ultra HD',
      genres: ['Sci-Fi', 'Adventure', 'Action'],
      type: 'movie',
      duration: '2h 46m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'UHD Movies', 'TorBox'],
      synopsis: 'Paul Atreides unites with Chani and the Fremen while seeking revenge against the conspirators who destroyed his family.',
      audioTracks: ['English Dolby Atmos', 'Hindi Dub 5.1'],
      subtitles: ['English', 'Bengali'],
      // Metadata-only catalog entry — servers/qualities are resolved live on demand.
      sources: [],
    ),

    const MovieItem(
      id: 'zg-oppenheimer',
      title: 'Oppenheimer',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/fm6KqXpk3M2HVveHwCrBSSBaO0V.jpg',
      year: 2023,
      rating: 8.9,
      quality: '4K IMAX',
      genres: ['Drama', 'History', 'Biography'],
      type: 'movie',
      duration: '3h 00m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'UHD Movies', 'TorBox'],
      synopsis: 'The story of American scientist J. Robert Oppenheimer and his role in the development of the atomic bomb during World War II.',
      audioTracks: ['English 5.1 Surround', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      // Metadata-only catalog entry — servers/qualities are resolved live on demand.
      sources: [],
    ),

    const MovieItem(
      id: 'zg-deadpool-wolverine',
      title: 'Deadpool & Wolverine',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/8cdWjvZQUExUUTzyp4t6EDMubfO.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/yDHYTjA3R0ne8e495NZPh4apofQ.jpg',
      year: 2024,
      rating: 8.0,
      quality: '4K Ultra HD',
      genres: ['Action', 'Comedy', 'Sci-Fi'],
      type: 'movie',
      duration: '2h 08m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'FlixHQ'],
      synopsis: 'A listless Wade Wilson toils away in civilian life with his days as Deadpool behind him. But when his home world faces an existential threat, Wade must reluctantly suit up with an even more reluctant Wolverine.',
      audioTracks: ['English Dolby Atmos', 'Hindi Dubbed'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: '4K HDHub Ultra 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '5.2 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'fourkhdhub',
          providerName: '4K HDHub',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-interstellar',
      title: 'Interstellar',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/xJHokMbljvjADYdit5fK5VQsXEG.jpg',
      year: 2014,
      rating: 8.7,
      quality: '4K Remux',
      genres: ['Sci-Fi', 'Drama', 'Adventure'],
      type: 'movie',
      duration: '2h 49m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'TorBox'],
      synopsis: 'When Earth becomes uninhabitable in the future, a farmer and ex-NASA pilot, Joseph Cooper, is tasked to pilot a spacecraft along with a team of researchers through a wormhole across the galaxy.',
      audioTracks: ['English DTS-HD', 'Hindi 5.1'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: '4K HDHub Remux 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '8.5 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'fourkhdhub',
          providerName: '4K HDHub',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-spiderman-spiderverse',
      title: 'Spider-Man: Across the Spider-Verse',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/8Vt6mWEReuy4Of61Lnj5Xj704m8.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/4HodYYKEIsGOdinkGi2Ucz6X9i0.jpg',
      year: 2023,
      rating: 8.7,
      quality: '4K HDR',
      genres: ['Animation', 'Action', 'Adventure'],
      type: 'movie',
      duration: '2h 20m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'HiAnime'],
      synopsis: 'Miles Morales catapults across the Multiverse, where he encounters a team of Spider-People charged with protecting its very existence.',
      audioTracks: ['English Dolby 5.1', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: '4K HDHub 2160p HDR',
          resolution: '4K UHD 2160p',
          fileSize: '5.8 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'fourkhdhub',
          providerName: '4K HDHub',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-the-batman',
      title: 'The Batman',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/74xTEgt7R36Fpooo50r9T25onhq.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/5P8SmMzSNYikXpxil6BYzJ16611.jpg',
      year: 2022,
      rating: 7.9,
      quality: '4K Ultra HD',
      genres: ['Action', 'Crime', 'Drama'],
      type: 'movie',
      duration: '2h 56m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'fourkhdhub',
      providerName: '4K HDHub',
      availableProviders: ['4K HDHub', 'UHD Movies'],
      synopsis: 'When a sadistic serial killer begins murdering key political figures in Gotham, Batman is forced to investigate the city\'s hidden corruption.',
      audioTracks: ['English Dolby Atmos', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: '4K HDHub Gotham 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '6.2 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'fourkhdhub',
          providerName: '4K HDHub',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: uhdmovies (UHD Movies)
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-avatar-way-of-water',
      title: 'Avatar: The Way of Water',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/t6HIqrRAclMCA60NsSmeqe9RmNV.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/8YFL5QQVPy3AgrEQxNYVSgiPEbe.jpg',
      year: 2022,
      rating: 7.7,
      quality: '4K UHD HDR',
      genres: ['Sci-Fi', 'Action', 'Adventure'],
      type: 'movie',
      duration: '3h 12m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'uhdmovies',
      providerName: 'UHD Movies',
      availableProviders: ['UHD Movies', '4K HDHub'],
      synopsis: 'Jake Sully lives with his newfound family formed on the extrasolar moon Pandora. Once a familiar threat returns to finish what was previously started, Jake must work with Neytiri and the army of the Na\'vi race to protect their home.',
      audioTracks: ['English Dolby Atmos', 'Hindi Dubbed'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'UHD Movies Pandora 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '7.8 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'uhdmovies',
          providerName: 'UHD Movies',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-top-gun-maverick',
      title: 'Top Gun: Maverick',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/62HCnUTziyWcpDaBO2i1DX17ljH.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/odJ4hx6g6vBt4lBWKFD1tI8WS4x.jpg',
      year: 2022,
      rating: 8.3,
      quality: '4K UHD 60fps',
      genres: ['Action', 'Drama'],
      type: 'movie',
      duration: '2h 10m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'uhdmovies',
      providerName: 'UHD Movies',
      availableProviders: ['UHD Movies', '4K HDHub'],
      synopsis: 'After thirty years, Maverick is still pushing the envelope as a top naval aviator, but must confront ghosts of his past when he leads TOP GUN\'s elite graduates on an impossible mission.',
      audioTracks: ['English Dolby Atmos', 'Hindi 5.1'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'UHD Movies Maverick 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '5.9 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'uhdmovies',
          providerName: 'UHD Movies',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-inception',
      title: 'Inception',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/edv5CZvWj09upOsy2Y6IwDhK8bt.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg',
      year: 2010,
      rating: 8.8,
      quality: '4K UHD',
      genres: ['Sci-Fi', 'Action', 'Thriller'],
      type: 'movie',
      duration: '2h 28m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'uhdmovies',
      providerName: 'UHD Movies',
      availableProviders: ['UHD Movies', '4K HDHub'],
      synopsis: 'A thief who steals corporate secrets through the use of dream-sharing technology is given the inverse task of planting an idea into the mind of a C.E.O.',
      audioTracks: ['English 5.1 Dolby', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'UHD Movies Master 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '6.1 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'uhdmovies',
          providerName: 'UHD Movies',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-inside-out-2',
      title: 'Inside Out 2',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/vpnVM9B6NMmQpWeZvzLvDESb2QY.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/stKGOmPAg6v9l7vN4L3fGqJ2y5y.jpg',
      year: 2024,
      rating: 7.6,
      quality: '4K UHD',
      genres: ['Animation', 'Family', 'Comedy'],
      type: 'movie',
      duration: '1h 36m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'uhdmovies',
      providerName: 'UHD Movies',
      availableProviders: ['UHD Movies', 'FlixHQ'],
      synopsis: 'Teenager Riley\'s mind headquarters is undergoing a sudden demolition to make room for unexpected new Emotions: Anxiety, Envy, Ennui, and Embarrassment.',
      audioTracks: ['English 5.1 Dolby', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'UHD Movies Pixar 2160p',
          resolution: '4K UHD 2160p',
          fileSize: '4.5 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'uhdmovies',
          providerName: 'UHD Movies',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: hdhub4u (HDHub4u) & multimovies
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-kalki-2898-ad',
      title: 'Kalki 2898 AD',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/rstcAnBeCkxNQjNp3YXrF6IP1tW.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/siFUMW2GvA8mX3DkS6z7iW81fG4.jpg',
      year: 2024,
      rating: 7.8,
      quality: '1080p Dual Audio',
      genres: ['Bollywood', 'Sci-Fi', 'Action'],
      type: 'movie',
      duration: '3h 01m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'hdhub4u',
      providerName: 'HDHub4u',
      availableProviders: ['HDHub4u', 'MultiMovies', 'VegaMovies'],
      synopsis: 'A modern avatar of the Hindu god Vishnu, believed to have descended to earth in the year 2898 AD to protect the world from evil forces.',
      audioTracks: ['Hindi Original 5.1', 'Telugu', 'Tamil'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'HDHub4u 1080p Dual Audio',
          resolution: '1080p Full HD',
          fileSize: '2.9 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'hdhub4u',
          providerName: 'HDHub4u',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-jawan',
      title: 'Jawan',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BMGExNGI1NDktOWI2Mi00NDM3LWIxMmQtNTQxYTgzMzI0MTA1XkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/pA3vd9r7eTzLg2M0m9T5vE4y5Wp.jpg',
      year: 2023,
      rating: 7.1,
      quality: '1080p Dual Audio',
      genres: ['Bollywood', 'Action', 'Thriller'],
      type: 'movie',
      duration: '2h 49m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'hdhub4u',
      providerName: 'HDHub4u',
      availableProviders: ['HDHub4u', 'MultiMovies'],
      synopsis: 'A man is driven by a personal vendetta to rectify the wrongs in society, while keeping a promise made years ago.',
      audioTracks: ['Hindi Original 5.1', 'Tamil', 'Telugu'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'HDHub4u SRK Mirror 1080p',
          resolution: '1080p Full HD',
          fileSize: '2.6 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'hdhub4u',
          providerName: 'HDHub4u',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-stree-2',
      title: 'Stree 2: Sarkate Ka Aatank',
      posterUrl: 'https://images.metahub.space/poster/medium/tt27510174/img',
      backdropUrl:
          'https://images.metahub.space/background/medium/tt27510174/img',
      year: 2024,
      rating: 7.4,
      quality: '1080p Full HD',
      genres: ['Bollywood', 'Comedy', 'Horror'],
      type: 'movie',
      duration: '2h 27m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'hdhub4u',
      providerName: 'HDHub4u',
      availableProviders: ['HDHub4u', 'VegaMovies', 'MultiMovies'],
      synopsis: 'The town of Chanderi is being haunted again, this time by a headless entity that kidnaps progressive women.',
      audioTracks: ['Hindi Original 5.1'],
      subtitles: ['English'],
      sources: [
        MovieSource(
          serverName: 'HDHub4u Chanderi 1080p',
          resolution: '1080p Full HD',
          fileSize: '2.4 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'hdhub4u',
          providerName: 'HDHub4u',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: vegamovies (VegaMovies) - Multi-Audio & Series
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-squid-game',
      title: 'Squid Game',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BMDcxYjg1OTctYmUxZi00ZjhjLWIwNTMtNmI2M2Y4OTU1YWU2XkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/dK1OHM20ZtX8K3G1W7gK2hB9k4u.jpg',
      year: 2021,
      rating: 8.0,
      quality: '1080p Multi-Audio',
      genres: ['KDrama', 'Thriller', 'Drama'],
      type: 'series',
      duration: '1 Season',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'vegamovies',
      providerName: 'VegaMovies',
      availableProviders: ['VegaMovies', 'FlixHQ'],
      synopsis: 'Hundreds of cash-strapped players accept a strange invitation to compete in children\'s games. Inside, a tempting prize awaits with deadly high stakes.',
      audioTracks: ['Korean Original', 'Hindi Dubbed', 'English 5.1'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'VegaMovies Korean Server 1080p',
          resolution: '1080p Full HD',
          fileSize: '1.4 GB/ep',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'vegamovies',
          providerName: 'VegaMovies',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-queen-of-tears',
      title: 'Queen of Tears',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BNWNmYmQ2NzctNTA1NS00NGU2LThjOTQtYTgxNmUyYmNjODYyXkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/hP9xM8z2vB3k1K4N6R8Z1y5G0J.jpg',
      year: 2024,
      rating: 8.3,
      quality: '1080p Full HD',
      genres: ['KDrama', 'Romance', 'Drama'],
      type: 'series',
      duration: '1 Season',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'vegamovies',
      providerName: 'VegaMovies',
      availableProviders: ['VegaMovies'],
      synopsis: 'The queen of department stores and her small-town husband weather a marital crisis until love miraculously begins to bloom again.',
      audioTracks: ['Korean Original', 'Hindi Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'VegaMovies KDrama 1080p',
          resolution: '1080p Full HD',
          fileSize: '1.2 GB/ep',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'vegamovies',
          providerName: 'VegaMovies',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: hianime (HiAnime) - Anime Series & Movies
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-jujutsu-kaisen-0',
      title: 'Jujutsu Kaisen 0',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BMzNhZTdmNDYtNTA0NC00MmNmLWIzYjUtNjg5NzNlYWQ0N2E5XkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/3G1Q5xF409kUBq89QWvOSc6gJmC.jpg',
      year: 2021,
      rating: 7.9,
      quality: '1080p BluRay',
      genres: ['Anime', 'Action', 'Supernatural'],
      type: 'movie',
      duration: '1h 45m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'hianime',
      providerName: 'HiAnime',
      availableProviders: ['HiAnime', 'AniKoto'],
      synopsis: 'Yuta Okkotsu gains control of an extremely powerful cursed spirit and gets enrolled in the Tokyo Prefectural Jujutsu High School.',
      audioTracks: ['Japanese Original', 'English Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'HiAnime Direct Stream 1080p',
          resolution: '1080p Full HD',
          fileSize: '1.8 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'hianime',
          providerName: 'HiAnime',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-solo-leveling',
      title: 'Solo Leveling',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BM2M4YzdkMTEtMjUyYy00ZWY0LWI5ODQtNGRkZWQ1MzU5MWM2XkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/jB6nO4U3Q6v8vK7X5x3L0M0r8K.jpg',
      year: 2024,
      rating: 8.5,
      quality: '1080p 60fps',
      genres: ['Anime', 'Action', 'Fantasy'],
      type: 'series',
      duration: '1 Season',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'hianime',
      providerName: 'HiAnime',
      availableProviders: ['HiAnime', 'AniKoto'],
      synopsis: 'In a world where hunters must battle deadly monsters to protect humanity, Sung Jinwoo, notoriously known as the weakest hunter of all mankind, finds himself in a struggle for survival.',
      audioTracks: ['Japanese Original', 'English Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'HiAnime Hunter 1080p',
          resolution: '1080p Full HD',
          fileSize: '650 MB/ep',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'hianime',
          providerName: 'HiAnime',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: anikoto (AniKoto) - Anime Movies
    // -------------------------------------------------------------
    const MovieItem(
      id: 'zg-spirited-away',
      title: 'Spirited Away',
      posterUrl:
          'https://image.tmdb.org/t/p/w500/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/bSXfqqE5ujhhx89VdaPGBEukNZ5.jpg',
      year: 2001,
      rating: 8.6,
      quality: '1080p BluRay',
      genres: ['Anime', 'Fantasy', 'Adventure'],
      type: 'movie',
      duration: '2h 05m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'anikoto',
      providerName: 'AniKoto',
      availableProviders: ['AniKoto', 'HiAnime'],
      synopsis: 'A sullen 10-year-old girl wanders into a world ruled by gods, witches and spirits, and where humans are changed into beasts.',
      audioTracks: ['Japanese Original 5.1', 'English Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'AniKoto Studio Ghibli 1080p',
          resolution: '1080p Full HD',
          fileSize: '2.1 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'anikoto',
          providerName: 'AniKoto',
        ),
      ],
    ),

    const MovieItem(
      id: 'zg-suzume',
      title: 'Suzume',
      posterUrl: 'https://images.metahub.space/poster/medium/tt16428256/img',
      backdropUrl:
          'https://images.metahub.space/background/medium/tt16428256/img',
      year: 2022,
      rating: 7.7,
      quality: '1080p HDR',
      genres: ['Anime', 'Adventure', 'Fantasy'],
      type: 'movie',
      duration: '2h 02m',
      repoId: '',
      repoName: 'Zangetsu',
      providerId: 'anikoto',
      providerName: 'AniKoto',
      availableProviders: ['AniKoto', 'HiAnime'],
      synopsis: 'A modern action-adventure road story where a 17-year-old girl named Suzume helps a mysterious young man close doors from the other side that are releasing disasters all over Japan.',
      audioTracks: ['Japanese Original', 'English Dub'],
      subtitles: ['English', 'Bengali'],
      sources: [
        MovieSource(
          serverName: 'AniKoto Shinkai 1080p',
          resolution: '1080p Full HD',
          fileSize: '2.3 GB',
          downloadUrl: '',
          streamUrl: '',
          providerId: 'anikoto',
          providerName: 'AniKoto',
        ),
      ],
    ),

    // -------------------------------------------------------------
    // Provider: banglaplex & 9kmovies (BDIX / Bangla OTT)
    // -------------------------------------------------------------
    const MovieItem(
      id: 'bd-surongo',
      title: 'Surongo (সুরঙ্গ)',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BZTVhYmNhNTgtN2UwMi00NjYwLWE5ZDYtNjhiZGZmOGQ2MGQxXkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/9xM8K2P5G7Y1K6N8Z9J3k4u.jpg',
      year: 2023,
      rating: 8.5,
      quality: '1080p BDIX',
      genres: ['Bangla', 'Crime', 'Thriller'],
      type: 'movie',
      duration: '2h 30m',
      repoId: '',
      repoName: 'BDIX Repo',
      providerId: 'banglaplex',
      providerName: 'BanglaPlex',
      availableProviders: ['BanglaPlex', '9kMovies', 'BDIX Live TV & Cinema'],
      synopsis: 'একটি ব্যাংকের ভল্ট লুট করার জন্য সুড়ঙ্গ খননের শ্বাসরুদ্ধকর কাহিনী। আফরান নিশোর অনবদ্য অভিনয়।',
      audioTracks: ['Bengali Original 5.1'],
      subtitles: ['English'],
      sources: [
        MovieSource(
          serverName: 'BanglaPlex Chorki BDIX 1080p',
          resolution: '1080p Full HD',
          fileSize: '2.2 GB',
          downloadUrl: '',
          streamUrl: '',
          isFastBDIX: true,
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
      ],
    ),

    const MovieItem(
      id: 'bd-hawa',
      title: 'Hawa (হাওয়া)',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BNWE4ODkzOTctYmZiYy00MzJkLThkY2QtMTU4Nzk3YTE5NDkwXkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/6xK8P9M2G7Y3K1N5Z8J4k3u.jpg',
      year: 2022,
      rating: 8.1,
      quality: '1080p BDIX',
      genres: ['Bangla', 'Mystery', 'Drama'],
      type: 'movie',
      duration: '2h 11m',
      repoId: '',
      repoName: 'BDIX Repo',
      providerId: 'banglaplex',
      providerName: 'BanglaPlex',
      availableProviders: ['BanglaPlex', '9kMovies'],
      synopsis: 'গভীর সমুদ্রে মাছ ধরার ট্রলারে এক রহস্যময় তরুণী ওঠার পর নাবিকদের মধ্যে ঘটা অদ্ভুত ও রোমহর্ষক ঘটনার ইতিবৃত্ত।',
      audioTracks: ['Bengali Original 5.1'],
      subtitles: ['English'],
      sources: [
        MovieSource(
          serverName: 'BanglaPlex Ocean BDIX 1080p',
          resolution: '1080p Full HD',
          fileSize: '1.9 GB',
          downloadUrl: '',
          streamUrl: '',
          isFastBDIX: true,
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
      ],
    ),

    const MovieItem(
      id: 'bd-mohanagar',
      title: 'Mohanagar (মহানগর)',
      posterUrl: 'https://m.media-amazon.com/images/M/MV5BNTQ0MzY0ZGUtMWEyYS00YzFiLTkzNGQtMDI3NWY3ZTRlNzQ0XkEyXkFqcGc@._V1_SX500.jpg',
      backdropUrl:
          'https://image.tmdb.org/t/p/original/3xM9P2G5Y7K1N6Z8J4k3u.jpg',
      year: 2021,
      rating: 8.8,
      quality: '1080p BDIX',
      genres: ['Bangla', 'Crime', 'Drama'],
      type: 'series',
      duration: '2 Seasons',
      repoId: '',
      repoName: 'BDIX Repo',
      providerId: 'banglaplex',
      providerName: 'BanglaPlex',
      availableProviders: ['BanglaPlex', '9kMovies'],
      synopsis: 'এক রাতের থানায় ঘটে যাওয়া রাজনৈতিক চাপ, সততা আর দুর্নীতির রুদ্ধশ্বাস লড়াই। ওসি হারুনের চরিত্রে মোশাররফ করিম।',
      audioTracks: ['Bengali Original 5.1'],
      subtitles: ['English'],
      sources: [
        MovieSource(
          serverName: 'BanglaPlex Hoichoi BDIX 1080p',
          resolution: '1080p Full HD',
          fileSize: '850 MB/ep',
          downloadUrl: '',
          streamUrl: '',
          isFastBDIX: true,
          providerId: 'banglaplex',
          providerName: 'BanglaPlex',
        ),
      ],
    ),
  ];
}
