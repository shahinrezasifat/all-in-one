import 'package:flutter/material.dart';
import '../models/extract_result.dart';
import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/permission_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_colors.dart';
import 'remote_image.dart';

class MovieDownloadSheet extends StatefulWidget {
  final MovieItem movie;
  final String? customTitle;

  const MovieDownloadSheet({
    super.key,
    required this.movie,
    this.customTitle,
  });

  static Future<void> show(
    BuildContext context, {
    required MovieItem movie,
    String? customTitle,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MovieDownloadSheet(
        movie: movie,
        customTitle: customTitle,
      ),
    );
  }

  @override
  State<MovieDownloadSheet> createState() => _MovieDownloadSheetState();
}

class _ServerOption {
  final String id;
  final String name;
  final String badge;
  final Color badgeColor;
  final String ping;
  final String description;
  final bool isFastBDIX;
  final String rawUrl;

  const _ServerOption({
    required this.id,
    required this.name,
    required this.badge,
    required this.badgeColor,
    required this.ping,
    required this.description,
    this.isFastBDIX = false,
    this.rawUrl = '',
  });
}

class _FormatOption {
  final String resolution;
  final String label;
  final String fileSize;
  final String badge;
  final LinearGradient gradient;
  final String note;
  final String format;
  final String rawUrl;
  final String formatId;

  const _FormatOption({
    required this.resolution,
    required this.label,
    required this.fileSize,
    required this.badge,
    required this.gradient,
    required this.note,
    required this.format,
    this.rawUrl = '',
    this.formatId = '',
  });
}

class _MovieDownloadSheetState extends State<MovieDownloadSheet> {
  int _selectedServerIndex = 0;
  int _selectedFormatIndex = 0;
  final String _targetFolderName = 'Movies';
  int _threadsCount = 6;

  bool _loading = true;
  bool _error = false;

  List<_ServerOption> _servers = const [];
  List<_FormatOption> _formats = const [];

  @override
  void initState() {
    super.initState();
    _resolveRealSources();
  }

  /// Live-resolves a GENUINE full movie source and populates only the qualities
  /// that source actually provides. No hardcoded servers or resolutions.
  Future<void> _resolveRealSources() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final result = await ExtractorService.instance
          .resolveMovieExtract(widget.movie.title)
          .timeout(const Duration(seconds: 15));
      if (result != null && mounted) {
        _buildFromExtract(result);
        setState(() {
          _loading = false;
          _error = _formats.isEmpty;
        });
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _loading = false;
        _error = _formats.isEmpty;
      });
    }
  }

  void _buildFromExtract(ExtractResult res) {
    final formats = <_FormatOption>[];
    for (final f in res.videoFormats) {
      if ((f.url ?? '').isEmpty) continue;
      formats.add(_FormatOption(
        resolution: f.label,
        label: f.label,
        fileSize: f.formattedSize,
        badge: _badgeFor(f.label),
        gradient: _gradientFor(f.label),
        note: f.note ?? 'Genuine source quality',
        format: f.ext,
        rawUrl: f.url ?? '',
        formatId: f.id,
      ));
    }

    _formats = formats;
    _servers = [
      _ServerOption(
        id: 'src_${res.platform}',
        name: '${res.platform} • ${res.title}',
        badge: 'RESOLVED',
        badgeColor: AppColors.primary,
        ping: 'live',
        description:
            'Verified real source • ${res.duration.isNotEmpty ? res.duration : 'duration unknown'}',
        isFastBDIX: false,
        rawUrl: res.originalUrl,
      ),
    ];
    _selectedServerIndex = 0;
    _selectedFormatIndex = 0;
  }

  String _badgeFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('2160') || l.contains('4k')) return '4K ULTRA HD';
    if (l.contains('1440') || l.contains('2k')) return '2K QHD';
    if (l.contains('1080')) return '1080p FHD';
    if (l.contains('720')) return '720p HD';
    if (l.contains('480')) return '480p SD';
    return 'HD';
  }

  LinearGradient _gradientFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('2160') || l.contains('4k')) {
      return const LinearGradient(colors: [Color(0xFFFFD700), Color(0xFFFF8C00)]);
    }
    if (l.contains('1440') || l.contains('2k')) {
      return const LinearGradient(colors: [Color(0xFF00C6FF), Color(0xFF0072FF)]);
    }
    if (l.contains('1080')) {
      return const LinearGradient(colors: [Color(0xFF00E676), Color(0xFF00B0FF)]);
    }
    if (l.contains('720')) {
      return const LinearGradient(colors: [Color(0xFF4FC3F7), Color(0xFF0288D1)]);
    }
    return const LinearGradient(colors: [Color(0xFF9E9E9E), Color(0xFF616161)]);
  }

  Widget _buildLoadingState() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.primary),
          ),
          SizedBox(height: 16),
          Text(
            'Analyzing real servers & available qualities…',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.primary),
          const SizedBox(height: 14),
          const Text(
            'No genuine source found',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Text(
            'This movie could not be resolved from a real source right now. Nothing is faked — check your connection and retry.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: _resolveRealSources,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            label: const Text(
              'Retry',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _onStartDownloadPressed() async {
    if (_servers.isEmpty || _formats.isEmpty) return;
    final selectedServer = _servers[_selectedServerIndex];
    final selectedFormat = _formats[_selectedFormatIndex];

    // A genuine source URL must exist — never start a fake download.
    final realUrl = selectedFormat.rawUrl.isNotEmpty ? selectedFormat.rawUrl : selectedServer.rawUrl;
    if (realUrl.isEmpty) return;

    // Ensure storage permissions are requested
    final hasPerm = await PermissionService.instance.hasStoragePermission();
    if (!hasPerm) {
      await PermissionService.instance.requestStoragePermission();
    }

    final source = MovieSource(
      serverName: selectedServer.name,
      resolution: selectedFormat.resolution,
      fileSize: selectedFormat.fileSize,
      format: selectedFormat.format,
      downloadUrl: realUrl,
      streamUrl: realUrl,
      isFastBDIX: selectedServer.isFastBDIX,
      repoId: widget.movie.repoId,
      repoName: widget.movie.repoName,
      providerId: widget.movie.providerId,
      providerName: widget.movie.providerName,
    );

    final titleToUse = widget.customTitle ?? widget.movie.title;

    final task = await DownloadManager.instance.startMovieDownload(
      movie: widget.movie,
      source: source,
      customTitle: titleToUse,
    );

    if (_targetFolderName != 'Movies' && _targetFolderName != 'Default') {
      await VirtualFolderService.instance.addItemToFolderByName(_targetFolderName, task.id);
    }

    if (mounted) {
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.darkCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: const Duration(seconds: 4),
          content: Row(
            children: [
              const Icon(Icons.download_done_rounded, color: AppColors.primary, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Downloading "$titleToUse"',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${selectedFormat.resolution} • ${selectedFormat.fileSize} on ${selectedServer.name.split('(').first.trim()}',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final title = widget.customTitle ?? widget.movie.title;
    final ready = !_loading && !_error && _servers.isNotEmpty && _formats.isNotEmpty;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
        maxWidth: 680,
      ),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 25,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBorder : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header: Poster & Title (single unified download view below)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: widget.movie.posterUrl.isNotEmpty
                      ? SmartNetworkImage(
                          url: widget.movie.posterUrl,
                          width: 48,
                          height: 64,
                          fit: BoxFit.cover,
                          placeholderColor: Colors.grey.shade800,
                          placeholderIcon: Icons.movie_rounded,
                          accentColor: Colors.white,
                        )
                      : Container(
                          width: 48,
                          height: 64,
                          color: Colors.grey.shade800,
                          child: const Icon(Icons.movie_rounded, color: Colors.white),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${widget.movie.year} • ${widget.movie.quality}',
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.movie.genres.isNotEmpty ? widget.movie.genres.take(2).join(', ') : 'Cinema',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Body: one unified view — server + resolution chosen together
          Expanded(
            child: _loading
                ? _buildLoadingState()
                : (_error || _servers.isEmpty || _formats.isEmpty)
                    ? _buildErrorState()
                    : _buildUnifiedView(isDark),
          ),

          if (ready) ...[
          // Bottom Action Bar
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : Colors.white,
            ),
            child: SafeArea(
              top: false,
              child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Quick options row (Folder & Threads)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            children: [
                              const Icon(Icons.bolt_rounded, size: 16, color: AppColors.primary),
                              const SizedBox(width: 6),
                              const Text(
                                'IDM Multi-Threads:',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 8),
                              ...[4, 6, 8].map((th) => Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text('${th}x', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      selected: _threadsCount == th,
                                      onSelected: (val) {
                                        if (val) setState(() => _threadsCount = th);
                                      },
                                      selectedColor: AppColors.primary,
                                      labelStyle: TextStyle(
                                        color: _threadsCount == th ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                                      ),
                                      backgroundColor: isDark ? AppColors.darkSurface : Colors.grey.shade200,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  )),
                              const SizedBox(width: 12),
                              Text(
                                _formats[_selectedFormatIndex].fileSize,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.primary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Big Download CTA
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              elevation: 4,
                              shadowColor: AppColors.primary.withValues(alpha: 0.45),
                            ),
                            onPressed: _onStartDownloadPressed,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.download_rounded, color: Colors.white, size: 22),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Download ${_formats[_selectedFormatIndex].resolution} • ${_formats[_selectedFormatIndex].fileSize}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildServerTile(int index, bool isDark) {
    final server = _servers[index];
    final isSelected = _selectedServerIndex == index;

    return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary.withValues(alpha: isDark ? 0.2 : 0.08)
                : (isDark ? AppColors.darkCard : Colors.grey.shade100),
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              setState(() {
                _selectedServerIndex = index;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  // Server Radio / Icon
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary
                          : (isDark ? AppColors.darkSurface : Colors.white),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: isSelected
                          ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
                          : Icon(Icons.dns_rounded, size: 18, color: isDark ? Colors.white60 : Colors.black54),
                    ),
                  ),
                  const SizedBox(width: 14),

                  // Server details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                server.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 14,
                                  color: isSelected ? AppColors.primary : null,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: server.badgeColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                server.badge,
                                style: TextStyle(
                                  color: server.badgeColor,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          server.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: Color(0xFF00E676),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Ping: ${server.ping} • High Speed IDM Parallel',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
  }

  Widget _buildFormatTile(int index, bool isDark) {
    final format = _formats[index];
    final isSelected = _selectedFormatIndex == index;

    return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: isDark ? 0.2 : 0.08)
                  : (isDark ? AppColors.darkCard : Colors.grey.shade100),
              borderRadius: BorderRadius.circular(16),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                setState(() {
                  _selectedFormatIndex = index;
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    // Radio button
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: isSelected
                          ? const Center(
                              child: Icon(Icons.check_rounded, color: Colors.white, size: 16),
                            )
                          : null,
                    ),
                    const SizedBox(width: 14),

                    // Details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  format.resolution,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                    fontSize: 14,
                                    color: isSelected ? AppColors.primary : null,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  gradient: format.gradient,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: format.badge.contains('4K')
                                      ? [
                                          BoxShadow(
                                            color: const Color(0xFFFFD700).withValues(alpha: 0.4),
                                            blurRadius: 6,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Text(
                                  format.badge,
                                  style: TextStyle(
                                    color: format.badge.contains('4K') ? Colors.black : Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            format.note,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? AppColors.darkTextTertiary : AppColors.lightTextTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // File size chip
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkSurface : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        format.fileSize,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
  }

  /// Single unified download view: server(s) and resolutions are shown together
  /// so the user picks both at once and taps Download — no wizard steps.
  Widget _buildUnifiedView(bool isDark) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      children: [
        _sectionHeader('SERVER', Icons.dns_rounded),
        const SizedBox(height: 8),
        ...List.generate(_servers.length, (i) => _buildServerTile(i, isDark)),
        const SizedBox(height: 14),
        _sectionHeader('RESOLUTION', Icons.high_quality_rounded),
        const SizedBox(height: 8),
        ...List.generate(_formats.length, (i) => _buildFormatTile(i, isDark)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _sectionHeader(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}
