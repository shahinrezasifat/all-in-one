import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/utils/episode_parser.dart';

void main() {
  test('seriesName groups individually downloaded episodes', () {
    expect(
      EpisodeParser.seriesName(
        'Devil May Cry - Season 1 · Episode 1 · Inferno (720p)',
      ),
      'devil may cry',
    );
    expect(
      EpisodeParser.seriesName(
        'Devil May Cry - Season 1 · Episode 2 · Our Lady of Sorrows (720p)',
      ),
      'devil may cry',
    );
    expect(
      EpisodeParser.seriesName('Episode 05 - Name (1080p)'),
      isNotEmpty,
    );
  });
}
