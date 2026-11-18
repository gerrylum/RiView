// the Android side of Record (MainActivity, RecorderService, ScreenCapture.kt)

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:opview/services/app_settings.dart' show RecordMethod;

/// a clip the head unit has finished writing
class SavedClip {
  final String path;
  final DateTime start;
  final Duration duration;
  final Duration buffered;
  const SavedClip(this.path, this.start, this.duration, this.buffered);
}

sealed class RecorderEvent {}

class ClipSavedEvent extends RecorderEvent {
  final SavedClip clip;
  ClipSavedEvent(this.clip);
}

class ClipFailedEvent extends RecorderEvent {
  final String message;
  ClipFailedEvent(this.message);
}

/// the screen capture ended without being asked (stopped from Android's own controls)
class CaptureEndedEvent extends RecorderEvent {}

abstract class RecorderPlatform {
  /// keep [buffer] ready. [RecordMethod.screen]: asks Android for the screen if not yet allowed
  /// this launch; [crop] in physical pixels inside the app's window. [RecordMethod.stream]: records
  /// the camera stream's video track [track] (no prompt). False when refused or not possible
  Future<bool> start({required Duration buffer, required Rect crop, RecordMethod method = RecordMethod.screen, String? track});

  /// the camera stream's video track changed (a reconnect, the other camera)
  Future<void> setTrack(String track);
  Future<void> stop();
  Future<void> setBuffer(Duration buffer);
  Future<void> setCrop(Rect crop);
  /// while paused the clip shows the last camera frame, dimmed, with "Recording paused" and [reason]
  Future<void> setPaused(bool paused, {String reason = ''});

  /// how much the clip includes from before now, or null with no capture running
  Future<Duration?> startClip();
  Future<void> stopClip();
  Future<String?> clipDir();
  Future<void> share(String path);
  Stream<RecorderEvent> get events;
}

class MethodChannelRecorder implements RecorderPlatform {
  static const _channel = MethodChannel('org.dragonpilot.opview/recorder');
  final _events = StreamController<RecorderEvent>.broadcast();

  MethodChannelRecorder() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'clipSaved':
          final a = Map<String, dynamic>.from(call.arguments as Map);
          _events.add(ClipSavedEvent(SavedClip(
            a['path'] as String,
            DateTime.fromMillisecondsSinceEpoch((a['startMs'] as num).toInt()),
            Duration(milliseconds: (a['durationMs'] as num).toInt()),
            Duration(milliseconds: (a['bufferedMs'] as num?)?.toInt() ?? 0),
          )));
        case 'clipFailed':
          _events.add(ClipFailedEvent(call.arguments as String? ?? 'Recording failed'));
        case 'captureEnded':
          _events.add(CaptureEndedEvent());
      }
      return null;
    });
  }

  Map<String, int> _rect(Rect r) =>
      {'x': r.left.round(), 'y': r.top.round(), 'w': r.width.round(), 'h': r.height.round()};

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;  // not on Android
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> start({required Duration buffer, required Rect crop, RecordMethod method = RecordMethod.screen, String? track}) async =>
      await _call<bool>('start', {
        'bufferMs': buffer.inMilliseconds,
        ..._rect(crop),
        'mode': method == RecordMethod.stream ? 'stream' : 'screen',
        if (track != null) 'track': track,
      }) ??
      false;

  @override
  Future<void> setTrack(String track) => _call('setTrack', track);

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<void> setBuffer(Duration buffer) => _call('setBuffer', buffer.inMilliseconds);

  @override
  Future<void> setCrop(Rect crop) => _call('setCrop', _rect(crop));

  @override
  Future<void> setPaused(bool paused, {String reason = ''}) => _call('setPaused', {'paused': paused, 'reason': reason});

  @override
  Future<Duration?> startClip() async {
    final ms = await _call<num>('startClip');
    return ms == null ? null : Duration(milliseconds: ms.toInt());
  }

  @override
  Future<void> stopClip() => _call('stopClip');

  @override
  Future<String?> clipDir() => _call<String>('clipDir');

  @override
  Future<void> share(String path) => _call('share', path);

  @override
  Stream<RecorderEvent> get events => _events.stream;
}
