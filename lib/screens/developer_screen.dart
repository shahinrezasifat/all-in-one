import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../theme/app_palette.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/github_profile_service.dart';

final _githubUsername = GithubProfileService.username;
final _githubProfile = GithubProfileService.profileUrl;

/// Neon palette used across the cyberpunk developer terminal.
final _neonCyan = AppPalette.current.primary;
final _neonMagenta = AppPalette.current.secondary;
final _neonLime = AppPalette.current.success;
final _void = AppPalette.current.background;
final _panel = AppPalette.current.card;

class DeveloperScreen extends StatefulWidget {
  DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen>
    with TickerProviderStateMixin {
  late final Future<GithubProfile?> _profile = GithubProfileService.fetch();
  final _avatarVersion = DateTime.now().millisecondsSinceEpoch.toString();

  /// One controller drives every staggered entrance; a second loops the
  /// neon glow / scanline pulse so the terminal feels alive.
  late final AnimationController _boot = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 2600),
  )..forward();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _boot.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// Fade + slide-up + slight scale, gated by [interval] — the core of the
  /// "one thing after another" hacking boot sequence.
  Widget _reveal(Widget child, Interval interval, {double offset = 34}) {
    final anim = CurvedAnimation(parent: _boot, curve: interval);
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(anim.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - t)),
            child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
          ),
        );
      },
    );
  }

  Widget _bootLine(String text, Interval interval, Color color) {
    final anim = CurvedAnimation(parent: _boot, curve: interval);
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final t = Curves.easeOut.transform(anim.value);
        final shown = (text.length * t).round();
        return Opacity(
          opacity: t > 0 ? 1 : 0,
          child: Text(
            '${text.substring(0, shown)}${shown < text.length ? '█' : ''}',
            style: TextStyle(
              fontFamily: 'monospace',
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: .5,
            ),
          ),
        );
      },
    );
  }

  static final _expertise = [
    (
      icon: Icons.code_rounded,
      code: '01',
      title: 'Software & App Development',
      description:
          'Full-stack web, Android, cross-platform and desktop apps, '
          'custom utilities, and audio plugins. Flutter, Laravel, PHP, '
          'Node.js, Python, MySQL, and SQLite.',
    ),
    (
      icon: Icons.movie_creation_outlined,
      code: '02',
      title: 'Video Production & Post-Production',
      description:
          'Video direction, cinematography, professional video '
          'editing, color grading, and motion graphics. DaVinci Resolve Studio, '
          'Adobe Premiere Pro, and After Effects.',
    ),
    (
      icon: Icons.graphic_eq_rounded,
      code: '03',
      title: 'Audio & Sound Engineering',
      description:
          'Commercial audio production, SFX mixing, sound design, '
          'and music production.',
    ),
    (
      icon: Icons.design_services_outlined,
      code: '04',
      title: 'Graphic & UI/UX Design',
      description:
          'Brand identity, UI/UX design, and commercial graphics. '
          'Photoshop and Illustrator.',
    ),
  ];

  static final _contacts = [
    (
      icon: Icons.mail_outline,
      title: 'Email',
      value: 'motionworkofficial@gmail.com',
      url: 'mailto:motionworkofficial@gmail.com',
    ),
    (
      icon: Icons.language,
      title: 'Website',
      value: 'motionwork-tali.top',
      url: 'https://motionwork-tali.top',
    ),
    (
      icon: Icons.code_rounded,
      title: 'GitHub',
      value: '@$_githubUsername',
      url: _githubProfile,
    ),
    (
      icon: Icons.ondemand_video,
      title: 'YouTube',
      value: '@SHAHINREZASIFAT2025',
      url: 'https://www.youtube.com/@SHAHINREZASIFAT2025',
    ),
    (
      icon: Icons.facebook,
      title: 'Facebook',
      value: 'Shahin.Reza.Sifat1997',
      url: 'https://www.facebook.com/Shahin.Reza.Sifat1997/',
    ),
    (
      icon: Icons.chat_outlined,
      title: 'WhatsApp',
      value: '+8801766522499',
      url: 'https://wa.me/8801766522499',
    ),
  ];

  Future<void> _openLink(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on PlatformException {
      // A device without a handler for the link may report a platform error.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not open this link.')));
  }

  // ---------------------------------------------------------------------------
  // Cyberpunk UI helpers
  // ---------------------------------------------------------------------------
  Widget _bg() => IgnorePointer(
    child: Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_void, context.palette.textSecondary, context.palette.tint(context.palette.primary, 0.05)],
            ),
          ),
        ),
        // Perspective grid floor.
        Positioned(
          left: -120,
          right: -120,
          bottom: -60,
          height: 320,
          child: Opacity(
            opacity: .22,
            child: CustomPaint(painter: _GridPainter()),
          ),
        ),
        Positioned(
          left: -140,
          top: -120,
          child: _orb(_neonCyan.withValues(alpha: .14), 340),
        ),
        Positioned(
          right: -150,
          top: 180,
          child: _orb(_neonMagenta.withValues(alpha: .12), 360),
        ),
        Positioned(
          left: 40,
          bottom: 200,
          child: _orb(_neonLime.withValues(alpha: .07), 260),
        ),
      ],
    ),
  );

  Widget _orb(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );

  Widget _neonPanel({
    required Widget child,
    Color? accent,
    EdgeInsetsGeometry? padding,
  }) {
    final panelAccent = accent ?? AppPalette.current.primary;
    final contentPadding = padding ?? const EdgeInsets.all(18);
    return Container(
      margin: EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: _panel.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: panelAccent.withValues(alpha: .28)),
        boxShadow: [
          BoxShadow(
            color: panelAccent.withValues(alpha: .10),
            blurRadius: 24,
            spreadRadius: -6,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Padding(padding: contentPadding, child: child),
        ),
      ),
    );
  }

  Widget _sectionLabel(String code, String label, Color accent) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: accent.withValues(alpha: .3)),
            ),
            child: Text(
              code,
              style: TextStyle(
                color: accent,
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(width: 10),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: accent,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.6,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Container(height: 1, color: accent.withValues(alpha: .25)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _void,
      appBar: AppBar(
        backgroundColor: _void.withValues(alpha: .85),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: _neonCyan,
        title: Row(
          children: [
            Icon(Icons.terminal_rounded, size: 18, color: _neonCyan),
            SizedBox(width: 10),
            Text(
              'DEV_PROFILE',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            Spacer(),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _neonLime,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _neonLime, blurRadius: 8)],
              ),
            ),
            SizedBox(width: 6),
            Text(
              'ONLINE',
              style: TextStyle(
                fontFamily: 'monospace',
                color: _neonLime,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: SizedBox.expand(),
          ),
        ),
      ),
      body: Stack(
        children: [
          _bg(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    // Boot sequence — types in one line after another.
                    _reveal(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _bootLine(
                            '> INITIALIZING DEV_PROFILE v2.0 ...',
                            Interval(0.00, 0.14),
                            _neonCyan,
                          ),
                          SizedBox(height: 4),
                          _bootLine(
                            '> ESTABLISHING GITHUB UPLINK ...',
                            Interval(0.10, 0.24),
                            _neonLime,
                          ),
                          SizedBox(height: 4),
                          _bootLine(
                            '> IDENTITY VERIFIED — ACCESS GRANTED',
                            Interval(0.20, 0.34),
                            _neonMagenta,
                          ),
                        ],
                      ),
                      Interval(0.0, 0.12),
                      offset: 12,
                    ),
                    SizedBox(height: 16),
                    _reveal(
                      FutureBuilder<GithubProfile?>(
                        future: _profile,
                        builder: (context, snapshot) {
                          return _buildProfileCard(
                            snapshot.data,
                            loading:
                                snapshot.connectionState !=
                                ConnectionState.done,
                          );
                        },
                      ),
                      Interval(0.18, 0.42),
                    ),
                    SizedBox(height: 20),
                    _reveal(
                      _sectionLabel('01', 'About Me', _neonCyan),
                      Interval(0.30, 0.46),
                    ),
                    _reveal(
                      _neonPanel(
                        accent: _neonCyan,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _terminalLine(
                              '> I have over 12 years of multidisciplinary experience in software development, multimedia production, and digital media.',
                            ),
                            SizedBox(height: 8),
                            _terminalLine(
                              '> Previously Senior Video Editor at GTV (Gazi TV).',
                            ),
                            SizedBox(height: 8),
                            _terminalLine(
                              '> Founder, CEO & Director of Motion Work (Production House & Digital Agency), Founder of Bee Creation and Sound Place.',
                            ),
                            SizedBox(height: 8),
                            _terminalLine(
                              '> Leading tech and creative operations at Guardian Event Management & Media Corporation.',
                            ),
                          ],
                        ),
                      ),
                      Interval(0.36, 0.56),
                    ),
                    _reveal(
                      _sectionLabel('02', 'What I Do', _neonMagenta),
                      Interval(0.48, 0.62),
                    ),
                    for (var i = 0; i < _expertise.length; i++)
                      _reveal(
                        _expertiseCard(
                          _expertise[i],
                          i.isEven ? _neonCyan : _neonMagenta,
                        ),
                        Interval(0.52 + i * 0.07, 0.68 + i * 0.07),
                      ),
                    SizedBox(height: 6),
                    _reveal(
                      _sectionLabel('03', 'Contact & Social', _neonLime),
                      Interval(0.78, 0.88),
                    ),
                    _reveal(
                      _neonPanel(
                        accent: _neonLime,
                        padding: EdgeInsets.all(8),
                        child: Column(
                          children: [
                            for (final contact in _contacts)
                              _contactRow(contact),
                          ],
                        ),
                      ),
                      Interval(0.82, 0.96),
                    ),
                    SizedBox(height: 10),
                    _reveal(
                      Center(
                        child: Text(
                          '// END OF FILE — TUB PURE SYSTEM',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: _neonCyan.withValues(alpha: .45),
                            fontSize: 10,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      Interval(0.92, 1.0),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _terminalLine(String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '›',
        style: TextStyle(
          fontFamily: 'monospace',
          color: _neonLime,
          fontSize: 13,
          fontWeight: FontWeight.w900,
        ),
      ),
      SizedBox(width: 10),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            color: context.palette.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    ],
  );

  Widget _buildProfileCard(GithubProfile? profile, {required bool loading}) {
    final avatar = profile?.avatarUrl ?? Uri.parse('$_githubProfile.png');
    final freshAvatar = avatar.replace(
      queryParameters: {...avatar.queryParameters, 't': _avatarVersion},
    );
    final repositories = profile?.publicRepositories;
    final username = profile?.username ?? _githubUsername;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _neonCyan.withValues(alpha: .16),
            _panel.withValues(alpha: .90),
            _neonMagenta.withValues(alpha: .10),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _neonCyan.withValues(alpha: .38), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: _neonCyan.withValues(alpha: .16),
            blurRadius: 30,
            spreadRadius: -8,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 22, 18, 20),
            child: Column(
              children: [
                // Profile ring
                Container(
                  padding: EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [_neonCyan, _neonMagenta],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _neonCyan.withValues(alpha: .35),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: context.palette.background,
                    child: ClipOval(
                      child: Image.network(
                        freshAvatar.toString(),
                        width: 92,
                        height: 92,
                        fit: BoxFit.cover,
                        semanticLabel: 'Developer profile photo',
                        errorBuilder: (context, error, stack) => Icon(
                          Icons.person_outline_rounded,
                          size: 44,
                          color: _neonCyan,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  'S. M. Shahin Reza Sifat',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.palette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.4,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'FULL-STACK DEVELOPER // CREATIVE DIRECTOR // FOUNDER, MOTION WORK',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: _neonCyan.withValues(alpha: .85),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .6,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Gazipur, Bangladesh',
                  style: TextStyle(color: context.palette.textSecondary, fontSize: 12),
                ),
                SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _statChip('@$username', _neonCyan),
                    _statChip(
                      repositories != null
                          ? '$repositories REPOS'
                          : loading
                          ? 'SYNCING…'
                          : 'STATS OFFLINE',
                      _neonLime,
                    ),
                    _statChip('12+ YEARS', _neonMagenta),
                  ],
                ),
                SizedBox(height: 18),
                // GitHub CTA — explicit LTR URL so it never looks reversed.
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: SizedBox(
                    width: double.infinity,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _openLink(_githubProfile),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [_neonCyan, context.palette.secondary],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: _neonCyan.withValues(alpha: .35),
                                blurRadius: 16,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.code_rounded, size: 17, color: _void),
                              SizedBox(width: 9),
                              Flexible(
                                child: Text(
                                  'github.com/$_githubUsername',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: _void,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              SizedBox(width: 6),
                              Icon(
                                Icons.open_in_new_rounded,
                                size: 14,
                                color: _void,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statChip(String label, Color color) => Container(
    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: .35)),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontFamily: 'monospace',
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: .5,
      ),
    ),
  );

  Widget _expertiseCard(
    ({IconData icon, String code, String title, String description}) item,
    Color accent,
  ) {
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _panel.withValues(alpha: .70),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: .26)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: .08),
            blurRadius: 16,
            spreadRadius: -6,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accent.withValues(alpha: .30)),
                  ),
                  child: Icon(item.icon, color: accent, size: 20),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '[${item.code}]',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.title.toUpperCase(),
                              style: TextStyle(
                                color: context.palette.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: .4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 7),
                      Text(
                        item.description,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: context.palette.textPrimary,
                          fontSize: 11,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _contactRow(
    ({IconData icon, String title, String value, String url}) contact,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openLink(contact.url),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              Icon(contact.icon, size: 18, color: _neonLime),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.title,
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(height: 2),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        contact.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: context.palette.textPrimary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new_rounded,
                size: 15,
                color: _neonLime.withValues(alpha: .8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _neonCyan
      ..strokeWidth = 1;
    final spacing = 26.0;
    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
