import '../models/movie_model.dart';

class LiveTvGroups {
  const LiveTvGroups({required this.countries, required this.languages});

  final Set<String> countries;
  final Set<String> languages;

  static const _countries = {
    'BD': 'Bangladesh',
    'IN': 'India',
    'PK': 'Pakistan',
    'LK': 'Sri Lanka',
    'NP': 'Nepal',
    'UK': 'United Kingdom',
    'GB': 'United Kingdom',
    'US': 'United States',
    'USA': 'United States',
    'CA': 'Canada',
    'AU': 'Australia',
    'FR': 'France',
    'DE': 'Germany',
    'IT': 'Italy',
    'ES': 'Spain',
    'SA': 'Saudi Arabia',
    'AE': 'United Arab Emirates',
    'TR': 'Turkey',
    'JP': 'Japan',
    'KR': 'South Korea',
  };

  static const _languages = {
    'Bengali': ['Bangla', 'Bengali', 'বাংলা'],
    'Hindi': ['Hindi', 'हिंदी'],
    'English': ['English'],
    'Urdu': ['Urdu'],
    'Tamil': ['Tamil'],
    'Telugu': ['Telugu'],
    'Malayalam': ['Malayalam'],
    'Kannada': ['Kannada'],
    'Punjabi': ['Punjabi'],
    'Arabic': ['Arabic'],
    'French': ['French'],
    'Spanish': ['Spanish'],
    'Turkish': ['Turkish'],
    'Japanese': ['Japanese'],
    'Korean': ['Korean'],
    'Portuguese': ['Portuguese'],
  };

  factory LiveTvGroups.fromChannel(MovieItem channel) {
    final countries = <String>{};
    final languages = <String>{};

    for (final label in [
      ...channel.catalogGroups,
      ...channel.genres,
      channel.title,
    ]) {
      final prefix = RegExp(r'^\s*\[?([A-Z]{2,3})\s*(?:\]|[|:\-])')
          .firstMatch(label)
          ?.group(1);
      final code = _countries[prefix ?? label.trim().toUpperCase()];
      if (code != null) countries.add(code);
      final text = label.toLowerCase();
      for (final country in _countries.values.toSet()) {
        if (_hasLabel(text, country.toLowerCase())) countries.add(country);
      }
      if (_hasLabel(text, 'indian')) countries.add('India');
      if (_hasLabel(text, 'bangladeshi')) countries.add('Bangladesh');
      for (final entry in _languages.entries) {
        if (entry.value.any((alias) => _hasLabel(text, alias.toLowerCase()))) {
          languages.add(entry.key);
        }
      }
      final explicit = RegExp(
        r'^\s*(country|region|language)\s*[:=]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(label);
      if (explicit != null) {
        final value = explicit.group(2)!.trim();
        final target = explicit.group(1)!.toLowerCase() == 'language'
            ? languages
            : countries;
        if (target.isEmpty && value.isNotEmpty) target.add(value);
      }
    }
    return LiveTvGroups(countries: countries, languages: languages);
  }

  static bool _hasLabel(String text, String label) =>
      RegExp(r'(^|[^a-z])' + RegExp.escape(label) + r'($|[^a-z])')
          .hasMatch(text);
}
