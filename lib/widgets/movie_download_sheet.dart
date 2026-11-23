import 'package:flutter/material.dart';
import '../models/extract_result.dart';
import '../models/movie_model.dart';
import '../services/download_manager.dart';
import '../services/extractor_service.dart';
import '../services/permission_service.dart';
import '../services/virtual_folder_service.dart';
import '../theme/app_palette.dart';
import 'remote_image.dart';

class MovieDownloadSheet extends StatefulWidget {
  final MovieItem movie;
  final String? customTitle;

  MovieDownloadSheet({
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

  _ServerOption({
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

  _FormatOption({
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

  List<_ServerOption> _servers = [];
  List<_FormatOption> _formats = [];

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
          .timeout(Duration(seconds: 15));
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
        badgeColor: context.palette.primary,
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
      return LinearGradient(colors: [context.palette.info, context.palette.info]);
    }
    if (l.contains('1440') || l.contains('2k')) {
      return LinearGradient(colors: [context.palette.info, context.palette.info]);
    }
    if (l.contains('1080')) {
      return LinearGradient(colors: [context.palette.success, context.palette.info]);
    }
    if (l.contains('720')) {
      return LinearGradient(colors: [context.palette.info, context.palette.info]);
    }
    return LinearGradient(colors: [context.palette.textSecondary, context.palette.textSecondary]);
  }

  Widget _buildLoadingState() {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 3, color: context.palette.primary),
          ),
          SizedBox(height: 16),
          Text(
            'Analyzing real servers & available qualities…',
            style: TextStyle(fontSize: 13, color: context.palette.onPrimary),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: context.palette.primary),
          SizedBox(height: 14),
          Text(
            'No genuine source found',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.palette.onPrimary),
          ),
          SizedBox(height: 8),
          Text(
            'This movie could not be resolved from a real source right now. Nothing is faked — check your connection and retry.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
          ),
          SizedBox(height: 18),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: context.palette.primary),
            onPressed: _resolveRealSources,
            icon: Icon(Icons.refresh_rounded, color: context.palette.onPrimary),
            label: Text(
              'Retry',
              style: TextStyle(color: context.palette.onPrimary, fontWeight: FontWeight.bold),
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
          backgroundColor: context.palette.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: Duration(seconds: 4),
          content: Row(
            children: [
              Icon(Icons.download_done_rounded, color: context.palette.primary, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Downloading "$titleToUse"',
                      style: TextStyle(fontWeight: FontWeight.bold, color: context.palette.onPrimary, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${selectedFormat.resolution} • ${selectedFormat.fileSize} on ${selectedServer.name.split('(').first.trim()}',
                      style: TextStyle(color: context.palette.textSecondary, fontSize: 11),
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
      margin: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(0.35),
            blurRadius: 25,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: EdgeInsets.only(top: 10, bottom: 8),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? context.palette.border : context.palette.textSecondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header: Poster & Title (single unified download view below)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
                          placeholderColor: context.palette.textSecondary,
                          placeholderIcon: Icons.movie_rounded,
                          accentColor: context.palette.card,
                        )
                      : Container(
                          width: 48,
                          height: 64,
                          color: context.palette.textSecondary,
                          child: Icon(Icons.movie_rounded, color: context.palette.onPrimary),
                        ),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: context.palette.tint(context.palette.primary, 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${widget.movie.year} • ${widget.movie.quality}',
                              style: TextStyle(
                                color: context.palette.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            widget.movie.genres.isNotEmpty ? widget.movie.genres.take(2).join(', ') : 'Cinema',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.palette.onPrimary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded),
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
            padding: EdgeInsets.fromLTRB(18, 12, 18, 20),
            decoration: BoxDecoration(
              color: context.palette.card,
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
                              Icon(Icons.bolt_rounded, size: 16, color: context.palette.primary),
                              SizedBox(width: 6),
                              Text(
                                'IDM Multi-Threads:',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              SizedBox(width: 8),
                              ...[4, 6, 8].map((th) => Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text('${th}x', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      selected: _threadsCount == th,
                                      onSelected: (val) {
                                        if (val) setState(() => _threadsCount = th);
                                      },
                                      selectedColor: context.palette.primary,
                                      labelStyle: TextStyle(
                                        color: _threadsCount == th ? context.palette.card : (isDark ? context.palette.textSecondary : context.palette.textPrimary),
                                      ),
                                      backgroundColor: context.palette.card,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  )),
                              SizedBox(width: 12),
                              Text(
                                _formats[_selectedFormatIndex].fileSize,
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.palette.primary),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 10),

                        // Big Download CTA
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.palette.primary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              elevation: 4,
                              shadowColor: context.palette.tint(context.palette.primary, 0.45),
                            ),
                            onPressed: _onStartDownloadPressed,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.download_rounded, color: context.palette.onPrimary, size: 22),
                                  SizedBox(width: 10),
                                  Text(
                                    'Download ${_formats[_selectedFormatIndex].resolution} • ${_formats[_selectedFormatIndex].fileSize}',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.palette.onScrim),
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
          margin: EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? context.palette.tint(context.palette.primary, isDark ? 0.2 : 0.08)
                : (isDark ? context.palette.card : context.palette.textSecondary),
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: context.palette.tint(context.palette.primary, 0.15),
                      blurRadius: 8,
                      offset: Offset(0, 3),
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
              padding: EdgeInsets.all(14),
              child: Row(
                children: [
                  // Server Radio / Icon
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? context.palette.primary
                          : (isDark ? context.palette.surface : context.palette.card),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: isSelected
                          ? Icon(Icons.check_rounded, color: context.palette.onPrimary, size: 22)
                          : Icon(Icons.dns_rounded, size: 18, color: context.palette.textSecondary),
                    ),
                  ),
                  SizedBox(width: 14),

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
                                  color: isSelected ? context.palette.primary : null,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                        SizedBox(height: 4),
                        Text(
                          server.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.palette.textSecondary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: context.palette.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Ping: ${server.ping} • High Speed IDM Parallel',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: context.palette.textSecondary,
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
            margin: EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? context.palette.tint(context.palette.primary, isDark ? 0.2 : 0.08)
                  : (isDark ? context.palette.card : context.palette.textSecondary),
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
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    // Radio button
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isSelected ? context.palette.primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: isSelected
                          ? Center(
                              child: Icon(Icons.check_rounded, color: context.palette.onScrim, size: 16),
                            )
                          : null,
                    ),
                    SizedBox(width: 14),

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
                                    color: isSelected ? context.palette.primary : null,
                                  ),
                                ),
                              ),
                              SizedBox(width: 8),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  gradient: format.gradient,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: format.badge.contains('4K')
                                      ? [
                                          BoxShadow(
                                            color: context.palette.info.withValues(alpha: 0.4),
                                            blurRadius: 6,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Text(
                                  format.badge,
                                  style: TextStyle(
                                    color: format.badge.contains('4K') ? context.palette.background : context.palette.card,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 2),
                          Text(
                            format.note,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.palette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // File size chip
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark ? context.palette.surface : context.palette.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        format.fileSize,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      children: [
        _sectionHeader('SERVER', Icons.dns_rounded),
        SizedBox(height: 8),
        ...List.generate(_servers.length, (i) => _buildServerTile(i, isDark)),
        SizedBox(height: 14),
        _sectionHeader('RESOLUTION', Icons.high_quality_rounded),
        SizedBox(height: 8),
        ...List.generate(_formats.length, (i) => _buildFormatTile(i, isDark)),
        SizedBox(height: 4),
      ],
    );
  }

  Widget _sectionHeader(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: context.palette.primary),
        SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: context.palette.primary,
          ),
        ),
      ],
    );
  }
}
