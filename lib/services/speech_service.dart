import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Free voice input backed by Android's built-in speech recognizer.
/// No API key, no network model download, no extra dependency.
class SpeechService {
  SpeechService._();

  static final SpeechService instance = SpeechService._();

  static const _channel = MethodChannel('snaptube_pure/speech');

  Future<String?> recognize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<String>('recognize');
    } on MissingPluginException catch (_) {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Voice input unavailable: ${error.message}');
      return null;
    }
  }
}
