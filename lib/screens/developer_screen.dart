import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const _githubUsername = 'shahinrezasifat1999';
const _githubProfile = 'https://github.com/$_githubUsername';

class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final _profile = _fetchProfile();
  final _avatarVersion = DateTime.now().millisecondsSinceEpoch.toString();

  static const _expertise = [
    (
      icon: Icons.code_rounded,
      title: 'Software & App Development',
      description:
          'Full-stack web, Android, cross-platform and desktop apps, '
          'custom utilities, and audio plugins. Flutter, Laravel, PHP, '
          'Node.js, Python, MySQL, and SQLite.',
    ),
    (
      icon: Icons.movie_creation_outlined,
      title: 'Video Production & Post-Production',
      description:
          'Video direction, cinematography, professional video '
          'editing, color grading, and motion graphics. DaVinci Resolve Studio, '
          'Adobe Premiere Pro, and After Effects.',
    ),
    (
      icon: Icons.graphic_eq_rounded,
      title: 'Audio & Sound Engineering',
      description:
          'Commercial audio production, SFX mixing, sound design, '
          'and music production.',
    ),
    (
      icon: Icons.design_services_outlined,
      title: 'Graphic & UI/UX Design',
      description:
          'Brand identity, UI/UX design, and commercial graphics. '
          'Photoshop and Illustrator.',
    ),
  ];

  static const _contacts = [
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
    ).showSnackBar(const SnackBar(content: Text('Could not open this link.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                FutureBuilder<_GitHubProfile?>(
                  future: _profile,
                  builder: (context, snapshot) {
                    final profile = snapshot.data;
                    return _buildProfileCard(
                      theme,
                      profile,
                      loading: snapshot.connectionState != ConnectionState.done,
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text('About Me', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'I have over 12 years of multidisciplinary experience in '
                  'software development, multimedia production, and digital '
                  'media. I previously served as Senior Video Editor at GTV '
                  '(Gazi TV).',
                ),
                const SizedBox(height: 8),
                const Text(
                  'I am the Founder, CEO & Director of Motion Work '
                  '(Production House & Digital Agency), the Founder of Bee '
                  'Creation (Creative Media & Web Series) and Sound Place '
                  '(Audio & Voice-over Studio), and I lead tech and creative '
                  'operations at Guardian Event Management & Media Corporation.',
                ),
                const SizedBox(height: 24),
                Text('What I Do', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final item in _expertise)
                        ListTile(
                          leading: Icon(item.icon),
                          title: Text(item.title),
                          subtitle: Text(item.description),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Contact & Social Links',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final contact in _contacts)
                        ListTile(
                          leading: Icon(contact.icon),
                          title: Text(contact.title),
                          subtitle: Text(contact.value),
                          trailing: const Icon(Icons.open_in_new, size: 18),
                          onTap: () => _openLink(contact.url),
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

  Widget _buildProfileCard(
    ThemeData theme,
    _GitHubProfile? profile, {
    required bool loading,
  }) {
    final avatar = profile?.avatar ?? Uri.parse('$_githubProfile.png');
    // A fresh image key on each visit lets GitHub photo changes appear
    // even when the avatar URL stays the same.
    final freshAvatar = avatar.replace(
      queryParameters: {...avatar.queryParameters, 't': _avatarVersion},
    );
    const placeholder = CircleAvatar(
      radius: 42,
      child: Icon(Icons.person_outline_rounded, size: 38),
    );
    final repositories = profile?.publicRepositories;
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            ClipOval(
              child: Image.network(
                freshAvatar.toString(),
                width: 84,
                height: 84,
                fit: BoxFit.cover,
                semanticLabel: 'Developer profile photo',
                frameBuilder: (context, child, frame, synchronous) =>
                    synchronous || frame != null ? child : placeholder,
                errorBuilder: (context, error, stack) => placeholder,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'S. M. Shahin Reza Sifat',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Full-Stack Software Developer, Creative Director & Founder of Motion Work',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text('Gazipur, Bangladesh', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'I build software and lead creative work across video, audio, and design.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                Chip(label: Text('@${profile?.username ?? _githubUsername}')),
                Chip(
                  label: Text(
                    repositories != null
                        ? 'Public repositories: $repositories'
                        : loading
                        ? 'Loading GitHub stats…'
                        : 'GitHub stats unavailable',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _openLink(_githubProfile),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('View GitHub profile'),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _GitHubProfile = ({
  String username,
  int? publicRepositories,
  Uri? avatar,
});

Future<_GitHubProfile?> _fetchProfile() async {
  final client = http.Client();
  try {
    final response = await client
        .get(
          Uri.https('api.github.com', '/users/$_githubUsername'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) return null;
    final login = data['login'];
    final repositories = data['public_repos'];
    final avatarUrl = data['avatar_url'];
    final avatar = avatarUrl is String ? Uri.tryParse(avatarUrl) : null;
    return (
      username: login is String && login.isNotEmpty ? login : _githubUsername,
      publicRepositories: repositories is int && repositories >= 0
          ? repositories
          : null,
      avatar:
          avatar?.scheme == 'https' &&
              avatar?.host == 'avatars.githubusercontent.com'
          ? avatar
          : null,
    );
  } on Exception {
    return null;
  } finally {
    client.close();
  }
}
