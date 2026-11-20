import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/extract_result.dart';
import 'package:snaptube_pure/services/extractor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});

  group('SnapTube Download Technology Tests', () {
    test('SnapTube standard audio formats (MP3 320k, 128k, M4A) and video badges are present', () async {
      final result = await ExtractorService.instance.extract('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(result, isNotNull);

      // Verify Video Formats and Badges
      expect(result!.videoFormats.isNotEmpty, true);
      final has4kOr2k = result.videoFormats.any((f) => f.badge == '4K' || f.badge == '2K');
      expect(has4kOr2k, true, reason: 'Must have 4K or 2K format with proper badge');

      final fhd = result.videoFormats.firstWhere((f) => f.label.contains('1080'), orElse: () => result.videoFormats.first);
      if (fhd.label.contains('1080')) {
        expect(fhd.badge, 'FHD');
      }

      final hd = result.videoFormats.firstWhere((f) => f.label.contains('720'), orElse: () => result.videoFormats.first);
      if (hd.label.contains('720')) {
        expect(hd.badge, 'HD');
      }

      // Verify SnapTube Audio Formats
      expect(result.audioFormats.isNotEmpty, true);
      final mp3320 = result.audioFormats.firstWhere((a) => a.label.contains('320'), orElse: () => result.audioFormats.first);
      expect(mp3320.label.contains('320'), true, reason: 'Must have MP3 320K HQ');
      expect(mp3320.badge, 'HQ');

      final mp3128 = result.audioFormats.where((a) => a.label.contains('128')).firstOrNull;
      expect(mp3128, isNotNull, reason: 'Must have MP3 128K FAST');
      expect(mp3128!.badge, 'FAST');

      final m4a = result.audioFormats.where((a) => a.ext == 'm4a' || a.label.contains('M4A')).firstOrNull;
      expect(m4a, isNotNull, reason: 'Must have M4A AAC');
      expect(m4a!.badge, 'M4A');
    });

    test('Dynamic size estimation correctly calculates bytes according to SnapTube specs', () {
      const durationSeconds = 300; // 5 minutes

      // Audio 320k: 5 min * 2.4MB = 12 MB
      final audio320Size = MediaFormat.estimateSizeBytes(
        durationSeconds: durationSeconds,
        type: MediaType.audio,
        resolutionOrBitrate: 'MP3 320K (HQ)',
      );
      expect(audio320Size, 5 * 2400 * 1024);

      // Audio 128k: 5 min * 1MB = 5 MB
      final audio128Size = MediaFormat.estimateSizeBytes(
        durationSeconds: durationSeconds,
        type: MediaType.audio,
        resolutionOrBitrate: 'MP3 128K',
      );
      expect(audio128Size, 5 * 1024 * 1024);

      // Video 1080p: 5 min * 32MB = 160 MB
      final video1080Size = MediaFormat.estimateSizeBytes(
        durationSeconds: durationSeconds,
        type: MediaType.video,
        resolutionOrBitrate: '1080p FHD',
      );
      expect(video1080Size, 5 * 32 * 1024 * 1024);

      // Video 4K: 5 min * 85MB = 425 MB
      final video4kSize = MediaFormat.estimateSizeBytes(
        durationSeconds: durationSeconds,
        type: MediaType.video,
        resolutionOrBitrate: '4K Ultra HD (2160p)',
      );
      expect(video4kSize, 5 * 85 * 1024 * 1024);
    });

    test('ExtractResult durationSeconds correctly converts formatted durations', () {
      const res1 = ExtractResult(
        id: '1',
        title: 'Test',
        author: 'Channel',
        duration: '03:45',
        thumbnailUrl: '',
        originalUrl: '',
        platform: 'Web',
        videoFormats: [],
        audioFormats: [],
      );
      expect(res1.durationSeconds, 3 * 60 + 45);

      const res2 = ExtractResult(
        id: '2',
        title: 'Test 2',
        author: 'Channel',
        duration: '01:15:30',
        thumbnailUrl: '',
        originalUrl: '',
        platform: 'Web',
        videoFormats: [],
        audioFormats: [],
      );
      expect(res2.durationSeconds, 3600 + 15 * 60 + 30);
    });
  });
}
