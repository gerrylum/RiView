// Record: keeps the last minute (or what Settings says) ready while connected, and makes a clip
// from it and what follows when Record is tapped, stopping at 5:00
// (design: claude/oprivview-record-gallery-design.md; the capture itself is ScreenCapture.kt).
// With "Camera + drive data" (claude/oprivview-telemetry-clips-design.md) the video is the comma's
// camera stream (StreamCapture.kt, no Android prompt) and the comma's messages are kept beside it
// (drive_data.dart), for the Gallery to draw the overlay from

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:opview/services/recorder/drive_data.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder_platform.dart';

/// clips stop by themselves at this length (ScreenCapture.kt MAX_CLIP_US)
const maxClipLength = Duration(minutes: 5);

/// how long the rail says Saved after a clip
const savedNoteFor = Duration(seconds: 4);

/// what happened while driving, kept long enough to cover any clip
class DriveEventLog {
  final DateTime Function() clock;
  final _events = <(DateTime, DriveEventKind)>[];
  bool? _engaged;
  String _alert = '';

  DriveEventLog({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  void observe(UIState st) {
    final engaged = st.isConnected && st.status != UIStatus.disengaged;
    final now = clock();
    if (_engaged != null && engaged != _engaged) {
      _events.add((now, engaged ? DriveEventKind.engaged : DriveEventKind.disengaged));
    }
    _engaged = engaged;
    final alert = st.alertSize > 0 && st.alertStatus > 0 ? st.alertText1 : '';
    if (alert.isNotEmpty && alert != _alert) _events.add((now, DriveEventKind.alert));
    _alert = alert;
    final keepFrom = now.subtract(maxClipLength * 3);
    _events.removeWhere((e) => e.$1.isBefore(keepFrom));
  }

  /// the events inside a clip, timed from its start
  List<DriveEvent> between(DateTime start, Duration length) => [
        for (final (t, kind) in _events)
          if (!t.isBefore(start) && t.difference(start) <= length) DriveEvent(t.difference(start), kind),
      ];
}

enum RecordState { off, buffering, recording }

class Recorder extends ChangeNotifier {
  final RecorderPlatform platform;
  final AppSettings settings;
  final UIState uiState;
  final DateTime Function() clock;
  final DriveEventLog log;

  RecordState state = RecordState.off;

  /// when the running clip begins (including what was buffered)
  DateTime? clipStart;

  /// the last clip written, shown on the rail for [savedNoteFor]
  DateTime? savedAt;
  Duration? savedLength;

  /// the last thing that went wrong, for a note
  String? lastError;

  /// goes up each time the clips change, so the Gallery reloads
  int clipsVersion = 0;

  /// the user said Not now (or Android refused) this launch: no buffer until Record is tapped
  bool declined = false;

  /// the camera stream's video track ("Camera + drive data" records it)
  final ValueListenable<String?>? videoTrack;

  ClipStore? _store;
  DriveDataLog? _log;
  /// how the running capture records (the setting may have changed since)
  RecordMethod _method = RecordMethod.screen;
  RecordMethod _wantMethod;
  /// the setting changed during a clip: switch after it
  bool _switchPending = false;
  StreamSubscription<RecorderEvent>? _sub;
  Timer? _ticker;
  Rect? _crop;
  bool _foreground = true;
  /// what covers the camera area ('Settings', 'Gallery', 'Navigate'), or null
  String? _coveredBy;
  bool _starting = false;
  int _bufferSeconds;

  /// [store] and [driveLog] replace the folders on the head unit (tests)
  Recorder({
    required this.platform,
    required this.settings,
    required this.uiState,
    this.videoTrack,
    DateTime Function()? clock,
    ClipStore? store,
    DriveDataLog? driveLog,
  })  : _store = store,
        _log = driveLog,
        clock = clock ?? DateTime.now,
        log = DriveEventLog(clock: clock),
        _bufferSeconds = settings.recordBufferSeconds,
        _wantMethod = settings.recordMethod {
    _sub = platform.events.listen(_onEvent);
    uiState.addListener(_onUiState);
    settings.addListener(_onSettings);
    videoTrack?.addListener(_onTrack);
  }

  bool get _stream => settings.recordMethod == RecordMethod.stream;

  /// the running capture records the camera stream
  bool get recordsStream => state != RecordState.off && _method == RecordMethod.stream;

  bool get recording => state == RecordState.recording;
  Duration get buffer => Duration(seconds: settings.recordBufferSeconds);

  /// how long the running clip is so far, held at 5:00
  Duration get clipLength {
    final s = clipStart;
    if (s == null) return Duration.zero;
    final d = clock().difference(s);
    return d > maxClipLength ? maxClipLength : d;
  }

  /// the rail says Saved for a few seconds after a clip
  bool get showsSaved => savedAt != null && clock().difference(savedAt!) < savedNoteFor && !recording;

  Future<DriveDataLog?> _driveLog() async {
    final l = _log;
    if (l != null) return l;
    final dir = await platform.clipDir();
    if (dir == null) return null;
    return _log = DriveDataLog(Directory('${Directory(dir).parent.path}/drive_blocks'));
  }

  /// one chunk from the comma's data channel, as it arrives (kept while recording the camera stream)
  void onDriveData(String chunk) {
    if (recordsStream) _log?.add(chunk);
  }

  Future<ClipStore?> store() async {
    final s = _store;
    if (s != null) return s;
    final dir = await platform.clipDir();
    if (dir == null) return null;
    return _store = ClipStore(Directory(dir));
  }

  // -- what the app tells it --

  /// the camera area and status bar, in physical pixels inside the app's window
  void setCrop(Rect crop) {
    if (crop == _crop) return;
    _crop = crop;
    if (state != RecordState.off) platform.setCrop(crop);
  }

  /// the app is in front (not in the background or a picture-in-picture window)
  void setForeground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    if (!value && recording) stopClip();
    _applyPause();
  }

  /// something covers the camera area (the Gallery): nothing new goes into the video meanwhile
  void setCameraHidden(bool value, {String by = 'A screen'}) => setCoveredBy(value ? by : null);

  /// [what] covers the camera area (null: nothing); the clip shows it as "Recording paused"
  void setCoveredBy(String? what) {
    if (what == _coveredBy) return;
    _coveredBy = what;
    _applyPause();
    notifyListeners();  // the rail's "paused" under the clip time
  }

  /// the camera area is covered (or the app is away), so the clip shows "Recording paused"
  /// (the camera stream is recorded whatever is on the screen)
  bool get paused => !_stream && (_coveredBy != null || !_foreground);

  void _applyPause() {
    if (state == RecordState.off || _method == RecordMethod.stream) return;
    final reason = !_foreground ? 'RiView is in the background' : (_coveredBy == null ? '' : '$_coveredBy open on the head unit');
    platform.setPaused(!_foreground || _coveredBy != null, reason: reason);
  }

  /// start keeping the buffer (screen recording asks Android the first time this launch); call when connected
  Future<void> startBuffer() async {
    if (state != RecordState.off || declined || _starting || settings.recordBufferSeconds == 0) return;
    if (!_foreground || !uiState.isConnected) return;
    if (_stream ? videoTrack?.value == null : _crop == null) return;
    await _startCapture();
  }

  Future<bool> _startCapture() async {
    final method = settings.recordMethod;
    final track = videoTrack?.value;
    if (method == RecordMethod.stream && track == null) return false;
    _starting = true;
    try {
      DriveDataLog? drive;
      if (method == RecordMethod.stream) {
        drive = await _driveLog();
        drive?.keep = buffer + maxClipLength + const Duration(seconds: 30);
      }
      final ok = await platform.start(buffer: buffer, crop: _crop ?? Rect.zero, method: method, track: track);
      if (!ok) {
        // screen recording: the user said no to Android's prompt (a failed stream start is tried again later)
        if (method == RecordMethod.screen) declined = true;
        notifyListeners();
        return false;
      }
      _method = method;
      if (drive != null) await drive.clear();
      state = RecordState.buffering;
      _applyPause();
      notifyListeners();
      return true;
    } finally {
      _starting = false;
    }
  }

  /// Record tapped: start a clip with what is buffered, or stop the one running
  Future<void> toggle() async {
    if (recording) return stopClip();
    if (_starting || (!_stream && _crop == null)) return;
    if (state == RecordState.off && !await _startCapture()) {
      if (_stream) {
        lastError = videoTrack?.value == null ? 'The camera is not showing yet' : 'Could not record the camera';
        notifyListeners();
      }
      return;
    }
    final before = await platform.startClip();
    if (before == null) {
      lastError = 'Recording is not running';
      notifyListeners();
      return;
    }
    declined = false;
    clipStart = clock().subtract(before);
    state = RecordState.recording;
    _tick();
    notifyListeners();
  }

  Future<void> stopClip() async {
    if (!recording) return;
    await platform.stopClip();
  }

  // -- what the head unit tells it --

  Future<void> _onEvent(RecorderEvent e) async {
    switch (e) {
      case ClipSavedEvent(:final clip):
        await _saved(clip);
      case ClipFailedEvent(:final message):
        lastError = message;
        if (recording) _clipEnded();
        notifyListeners();
      case CaptureEndedEvent():
        if (_method == RecordMethod.stream) return;  // the screen capture's (an old one, stopped)
        state = RecordState.off;
        clipStart = null;
        declined = true;
        notifyListeners();
    }
  }

  Future<void> _saved(SavedClip saved) async {
    _clipEnded();
    savedAt = clock();
    savedLength = saved.duration;
    final s = await store();
    if (s != null) {
      final video = File(saved.path);
      var drive = false;
      if (_method == RecordMethod.stream) {
        final l = await _driveLog();
        drive = l != null && await l.writeClip(driveDataFor(video), saved.start, saved.duration);
      }
      final clip = Clip(
        video: video,
        start: saved.start,
        duration: saved.duration,
        buffered: saved.buffered,
        events: log.between(saved.start, saved.duration),
        hasDriveData: drive,
      );
      await s.save(clip);
      await s.enforceLimit(settings.storageLimitGb * 1024 * 1024 * 1024);
    }
    clipsVersion++;
    // with no buffer the capture only ran for the clip
    if (settings.recordBufferSeconds == 0 && state != RecordState.off) {
      await platform.stop();
      state = RecordState.off;
    }
    _tick();
    notifyListeners();
    if (_switchPending) await _switchMethod();
  }

  /// Settings › Recording chose the other method: stop the capture and start the new one
  Future<void> _switchMethod() async {
    if (recording) {
      _switchPending = true;
      return;
    }
    _switchPending = false;
    if (state != RecordState.off) {
      await platform.stop();
      state = RecordState.off;
      clipStart = null;
      await _log?.clear();
    }
    declined = false;
    notifyListeners();
    // screen recording's first start goes through the explainer (app_shell.dart)
    if (_stream || settings.recordExplained) await startBuffer();
  }

  /// the camera stream's track changed: record the new one, or start once there is one
  void _onTrack() {
    final id = videoTrack?.value;
    if (id == null || !_stream) return;
    if (recordsStream) {
      platform.setTrack(id);
    } else if (state == RecordState.off) {
      startBuffer();
    }
  }

  void _clipEnded() {
    clipStart = null;
    if (state == RecordState.recording) state = RecordState.buffering;
  }

  // the rail's clock: once a second while recording or showing Saved
  void _tick() {
    _ticker?.cancel();
    if (!recording && !showsSaved) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
      if (!recording && !showsSaved) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  bool _wasConnected = false;

  void _onUiState() {
    log.observe(uiState);
    // the camera stream needs no prompt: start as soon as there is something to record
    final connected = uiState.isConnected;
    if (connected && !_wasConnected && _stream) startBuffer();
    _wasConnected = connected;
  }

  void _onSettings() {
    if (settings.recordMethod != _wantMethod) {
      _wantMethod = settings.recordMethod;
      _switchMethod();
    }
    final s = settings.recordBufferSeconds;
    if (s == _bufferSeconds) return;
    _bufferSeconds = s;
    if (state == RecordState.off) {
      declined = false;
      startBuffer();
    } else if (s == 0 && !recording) {
      platform.stop();
      state = RecordState.off;
      notifyListeners();
    } else {
      platform.setBuffer(buffer);
      _log?.keep = buffer + maxClipLength + const Duration(seconds: 30);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    uiState.removeListener(_onUiState);
    settings.removeListener(_onSettings);
    videoTrack?.removeListener(_onTrack);
    super.dispose();
  }
}
