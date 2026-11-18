// the recorded clips on the head unit: <start ms>.mp4 with a .json beside it (length, star, what
// happened during it) and a .jpg thumbnail, all in the app's own clips folder. A "Camera + drive
// data" clip also has <start ms>.drive.gz, the comma's messages to draw the overlay from (drive_data.dart)

import 'dart:convert';
import 'dart:io';

/// something that happened during a clip, for the player's scrubber
enum DriveEventKind { engaged, disengaged, alert }

class DriveEvent {
  final Duration at;  // from the start of the clip
  final DriveEventKind kind;
  const DriveEvent(this.at, this.kind);

  Map<String, dynamic> toJson() => {'ms': at.inMilliseconds, 'kind': kind.name};

  static DriveEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final ms = j['ms'], kind = j['kind'];
    if (ms is! num || kind is! String) return null;
    for (final k in DriveEventKind.values) {
      if (k.name == kind) return DriveEvent(Duration(milliseconds: ms.toInt()), k);
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is DriveEvent && other.at == at && other.kind == kind;

  @override
  int get hashCode => Object.hash(at, kind);
}

class Clip {
  final File video;
  final DateTime start;
  final Duration duration;
  final Duration buffered;  // the part from before the tap on Record
  final bool starred;
  final List<DriveEvent> events;
  final int bytes;

  /// the video is the camera alone, and [driveData] has what to draw over it
  final bool hasDriveData;

  const Clip({
    required this.video,
    required this.start,
    required this.duration,
    this.buffered = Duration.zero,
    this.starred = false,
    this.events = const [],
    this.bytes = 0,
    this.hasDriveData = false,
  });

  String get id => video.uri.pathSegments.last.replaceAll('.mp4', '');
  File get meta => File(video.path.replaceAll(RegExp(r'\.mp4$'), '.json'));
  File get thumbnail => File(video.path.replaceAll(RegExp(r'\.mp4$'), '.jpg'));
  File get driveData => driveDataFor(video);
  bool get hasAlert => events.any((e) => e.kind == DriveEventKind.alert);

  Clip copyWith({bool? starred}) => Clip(
        video: video,
        start: start,
        duration: duration,
        buffered: buffered,
        starred: starred ?? this.starred,
        events: events,
        bytes: bytes,
        hasDriveData: hasDriveData,
      );

  Map<String, dynamic> toJson() => {
        'startMs': start.millisecondsSinceEpoch,
        'durationMs': duration.inMilliseconds,
        'bufferedMs': buffered.inMilliseconds,
        'starred': starred,
        'events': [for (final e in events) e.toJson()],
      };
}

/// where a clip's drive data goes
File driveDataFor(File video) => File(video.path.replaceAll(RegExp(r'\.mp4$'), '.drive.gz'));

class ClipStore {
  final Directory dir;
  ClipStore(this.dir);

  /// newest first
  Future<List<Clip>> list() async {
    if (!await dir.exists()) return [];
    final clips = <Clip>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.mp4')) continue;
      final clip = await _read(f);
      if (clip != null) clips.add(clip);
    }
    clips.sort((a, b) => b.start.compareTo(a.start));
    return clips;
  }

  Future<Clip?> _read(File video) async {
    final name = video.uri.pathSegments.last.replaceAll('.mp4', '');
    final startMs = int.tryParse(name);
    int bytes = 0;
    try {
      bytes = await video.length();
    } catch (_) {
      return null;
    }
    var hasDriveData = false;
    try {
      final drive = driveDataFor(video);
      if (await drive.exists()) {
        hasDriveData = true;
        bytes += await drive.length();
      }
    } catch (_) {}
    Map<String, dynamic> j = const {};
    final meta = File(video.path.replaceAll(RegExp(r'\.mp4$'), '.json'));
    try {
      if (await meta.exists()) j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // an unreadable sidecar: the clip still plays
    }
    final start = (j['startMs'] as num?)?.toInt() ?? startMs;
    if (start == null) return null;
    return Clip(
      video: video,
      start: DateTime.fromMillisecondsSinceEpoch(start),
      duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
      buffered: Duration(milliseconds: (j['bufferedMs'] as num?)?.toInt() ?? 0),
      starred: j['starred'] as bool? ?? false,
      events: (j['events'] as List? ?? const []).map(DriveEvent.fromJson).whereType<DriveEvent>().toList(),
      bytes: bytes,
      hasDriveData: hasDriveData,
    );
  }

  Future<void> save(Clip clip) => clip.meta.writeAsString(jsonEncode(clip.toJson()));

  Future<Clip> setStarred(Clip clip, bool starred) async {
    final c = clip.copyWith(starred: starred);
    await save(c);
    return c;
  }

  Future<void> delete(Clip clip) async {
    for (final f in [clip.video, clip.meta, clip.thumbnail, clip.driveData]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// remove the oldest unstarred clips until the rest fit in [limitBytes]; returns what was removed
  Future<List<Clip>> enforceLimit(int limitBytes) async {
    final removed = clipsToRemove(await list(), limitBytes);
    for (final c in removed) {
      await delete(c);
    }
    return removed;
  }
}

/// the oldest unstarred clips to remove so the rest fit in [limitBytes] (clips newest first)
List<Clip> clipsToRemove(List<Clip> clips, int limitBytes) {
  var total = clips.fold<int>(0, (sum, c) => sum + c.bytes);
  final out = <Clip>[];
  for (final c in clips.reversed) {
    if (total <= limitBytes) break;
    if (c.starred) continue;
    out.add(c);
    total -= c.bytes;
  }
  return out;
}

/// "96 MB", "1.6 GB"
String formatBytes(int bytes) {
  const mb = 1024 * 1024, gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).round()} MB';
}
