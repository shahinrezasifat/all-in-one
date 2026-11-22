import 'movie_model.dart';

const movieSourceLanguageLabels = {
  'hi': 'Hindi',
  'bn': 'Bangla',
  'en': 'English',
  'ta': 'Tamil',
  'te': 'Telugu',
  'ml': 'Malayalam',
  'kn': 'Kannada',
  'pa': 'Punjabi',
  'mr': 'Marathi',
  'gu': 'Gujarati',
  'ur': 'Urdu',
  'ko': 'Korean',
  'ja': 'Japanese',
  'zh': 'Chinese',
  'th': 'Thai',
  'id': 'Indonesian',
  'es': 'Spanish',
  'fr': 'French',
  'pt': 'Portuguese',
  'de': 'German',
  'ru': 'Russian',
  'it': 'Italian',
  'ar': 'Arabic',
  'tr': 'Turkish',
  'dual': 'Dual audio',
  'multi': 'Multi audio',
  'orig': 'Original',
};

final _languagePatterns = {
  for (final entry in const {
    'hi': 'hindi|hin',
    'bn': 'bangla|bengali|ben',
    'en': 'english|eng',
    'ta': 'tamil|tam',
    'te': 'telugu|tel',
    'ml': 'malayalam|mal',
    'kn': 'kannada|kan',
    'pa': 'punjabi|pan',
    'mr': 'marathi|mar',
    'gu': 'gujarati|guj',
    'ur': 'urdu|urd',
    'ko': 'korean|kor',
    'ja': 'japanese|jpn',
    'zh': 'chinese|mandarin|cantonese|chi|zho',
    'th': 'thai|tha',
    'id': 'indonesian|ind',
    'es': 'spanish|español|espanol|spa',
    'fr': 'french|français|francais|fra',
    'pt': 'portuguese|por',
    'de': 'german|deu',
    'ru': 'russian|rus',
    'it': 'italian|ita',
    'ar': 'arabic|ara',
    'tr': 'turkish|tur',
    'dual': 'dual|2 audio',
    'multi': 'multi|all audio',
  }.entries)
    entry.key: RegExp(r'\b(?:' + entry.value + r')\b', caseSensitive: false),
};

List<String> movieSourceLanguageKeys(MovieSource source) {
  final label = '${source.serverName} ${source.resolution}'.replaceAll(
    RegExp(r'[-_./]+'),
    ' ',
  );
  final keys = [
    for (final entry in _languagePatterns.entries)
      if (entry.value.hasMatch(label)) entry.key,
  ];
  return keys.isEmpty ? const ['orig'] : keys;
}

/// Keeps a provider's explicit height, including nonstandard HLS heights.
String episodeDownloadResolution(MovieSource source) {
  final height = RegExp(r'^(\d{3,4})p$', caseSensitive: false)
      .firstMatch(source.resolution.trim())?.group(1);
  return height == null ? 'Auto' : '${height}p';
}
