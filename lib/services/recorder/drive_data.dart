// "Camera + drive data" clips (design: claude/oprivview-telemetry-clips-design.md): the comma's
// messages from the data channel, each with the time it arrived, saved beside a clip as
// <start ms>.drive.gz so the Gallery can draw the overlay over the camera video again.
//
// While Record is ready the messages go into 10 s blocks, each written to a gzip file in the
// background, and blocks older than the buffer plus a whole clip are deleted. A block file starts
// with the newest message of each kind from before it (lines marked p), so a clip has the
// calibration, car and settings messages that only come now and then. A clip's file is the
// blocks it covers cut to its time, from [driveDataLead] before it.
//
// File format: gzip, one message per line, "<ms>\t<message>" (p<ms> for the ones from before)

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

/// a clip's drive data starts this long before it, so the overlay is settled at 0:00
const driveDataLead = Duration(seconds: 3);

/// a seek further back (or forward) than this replays from the newest messages before it
const _replayWarmUp = Duration(seconds: 3);

/// how far behind a seek can be without starting again (ms)
const _replaySlack = 400;

const _blockMs = 10000;

/// at most about 20 a second of each kind are kept (carState and others come at 100 Hz)
const _minGapMs = 45;

final _typeRe = RegExp(r'"type"\s*:\s*"([A-Za-z0-9_]+)"');

/// the kind of message ("carState"), or '' for a chunk that is several messages, part of one, or has no type
String messageType(String chunk) {
  if (!chunk.startsWith('{') || chunk.contains('}{')) return '';
  return _typeRe.firstMatch(chunk)?.group(1) ?? '';
}

class DriveLine {
  final int t;  // wall clock, ms since epoch
  final String type;
  final String chunk;
  const DriveLine(this.t, this.type, this.chunk);
}

String _line(DriveLine l, {bool primer = false}) => '${primer ? 'p' : ''}${l.t}\t${l.chunk.replaceAll('\n', ' ')}\n';

class _Block {
  final int startMs;
  final List<DriveLine> primer;
  final lines = <DriveLine>[];
  int endMs;
  File? file;          // set once written
  Future<void>? writing;
  _Block(this.startMs, this.primer) : endMs = startMs;
}

/// runs [job] off the UI thread ([inline] for tests)
Future<T> _run<T>(T Function() job, bool inline) => inline ? Future.sync(job) : Isolate.run(job);

class DriveDataLog {
  final Directory dir;
  final int Function() nowMs;

  /// how far back blocks are kept: the buffer, a whole clip and a margin
  Duration keep;

  /// work in this isolate (tests)
  final bool inline;

  final _blocks = <_Block>[];
  final _latest = <String, DriveLine>{};
  final _lastKept = <String, int>{};
  bool _cleared = false;

  DriveDataLog(this.dir, {int Function()? nowMs, this.keep = const Duration(minutes: 8), this.inline = false})
      : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// one chunk from the data channel, as it arrives
  void add(String chunk) {
    final t = nowMs();
    final type = messageType(chunk);
    if (type.isNotEmpty) {
      final last = _lastKept[type];
      if (last != null && t >= last && t - last < _minGapMs) return;
      _lastKept[type] = t;
    }
    var b = _blocks.isEmpty ? null : _blocks.last;
    if (b == null || b.file != null || b.writing != null || t - b.startMs >= _blockMs) {
      if (b != null && b.writing == null && b.file == null) _write(b);
      b = _Block(t, _latest.values.toList()..sort((x, y) => x.t.compareTo(y.t)));
      _blocks.add(b);
      _trim(t);
    }
    final line = DriveLine(t, type, chunk);
    b.lines.add(line);
    b.endMs = t;
    if (type.isNotEmpty) _latest[type] = line;
  }

  /// forget everything (Record turned off, or another method chosen)
  Future<void> clear() async {
    final old = [..._blocks];
    _blocks.clear();
    _latest.clear();
    _lastKept.clear();
    for (final b in old) {
      await b.writing;
      try {
        await b.file?.delete();
      } catch (_) {}
    }
  }

  Future<void> _ensureDir() async {
    if (_cleared) return;
    _cleared = true;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);  // left from the last run
    } catch (_) {}
    await dir.create(recursive: true);
  }

  void _write(_Block b) {
    final lines = b.lines.toList(), primer = b.primer;
    final path = '${dir.path}/${b.startMs}.gz';
    b.writing = () async {
      try {
        await _ensureDir();
        await _writeBlockOff(path, primer, lines, inline);
        b.file = File(path);
        b.lines.clear();  // on disk now
      } catch (e) {
        debugPrint('[opview] drive data block: $e');
      }
    }();
  }

  void _trim(int now) {
    final keepFrom = now - keep.inMilliseconds;
    while (_blocks.length > 1 && _blocks.first.endMs < keepFrom) {
      final old = _blocks.removeAt(0);
      final w = old.writing;
      if (w == null) continue;
      () async {
        try {
          await w;
          await old.file?.delete();
        } catch (_) {}
      }();
    }
  }

  /// write the messages from [driveDataLead] before [start] to [start] + [length] into [out];
  /// false when there are none
  Future<bool> writeClip(File out, DateTime start, Duration length) async {
    final from = start.subtract(driveDataLead).millisecondsSinceEpoch;
    final to = start.add(length).millisecondsSinceEpoch + 500;
    final picked = _blocks.where((b) => b.endMs >= from && b.startMs <= to).toList();
    if (picked.isEmpty) return false;
    // the newest block is still in memory; the rest wait for their files
    final files = <String>[];
    final memory = <DriveLine>[];
    for (final b in picked) {
      await b.writing;
      if (b.file != null) {
        files.add(b.file!.path);
      } else {
        memory.addAll(b.lines);
      }
    }
    final primer = picked.first.primer;
    try {
      return await _cutOff(files, primer, memory, from, to, out.path, inline);
    } catch (e) {
      debugPrint('[opview] drive data clip: $e');
      return false;
    }
  }
}

// (made in functions of their own: a closure sent to another isolate takes everything in the
// scope it was made in along, and a block's Future can't be sent)
Future<void> _writeBlockOff(String path, List<DriveLine> primer, List<DriveLine> lines, bool inline) =>
    _run(() => _writeBlock(path, primer, lines), inline);

Future<bool> _cutOff(List<String> files, List<DriveLine> primer, List<DriveLine> memory, int from, int to, String out, bool inline) =>
    _run(() => _cut(files, primer, memory, from, to, out), inline);

void _writeBlock(String path, List<DriveLine> primer, List<DriveLine> lines) {
  final text = StringBuffer();
  for (final l in primer) {
    text.write(_line(l, primer: true));
  }
  for (final l in lines) {
    text.write(_line(l));
  }
  File(path).writeAsBytesSync(gzip.encode(utf8.encode(text.toString())));
}

/// the clip's file: the first block's messages from before, then everything in [from, to]
bool _cut(List<String> files, List<DriveLine> primer, List<DriveLine> memory, int from, int to, String out) {
  final text = StringBuffer();
  var count = 0;
  var first = true;
  void take(DriveLine l, bool isPrimer) {
    if (isPrimer) {
      text.write(_line(l, primer: true));
    } else if (l.t >= from && l.t <= to) {
      text.write(_line(l));
      count++;
    }
  }

  if (files.isEmpty) {
    for (final l in primer) {
      take(l, true);
    }
  }
  for (final path in files) {
    for (final (l, isPrimer) in _parse(utf8.decode(gzip.decode(File(path).readAsBytesSync()), allowMalformed: true))) {
      // only the first block's messages from before matter; later ones repeat what came in between
      if (isPrimer && !first) continue;
      take(l, isPrimer);
    }
    first = false;
  }
  for (final l in memory) {
    take(l, false);
  }
  if (count == 0) return false;
  File(out).writeAsBytesSync(gzip.encode(utf8.encode(text.toString())));
  return true;
}

Iterable<(DriveLine, bool)> _parse(String text) sync* {
  for (final raw in const LineSplitter().convert(text)) {
    final tab = raw.indexOf('\t');
    if (tab <= 0) continue;
    final primer = raw.startsWith('p');
    final t = int.tryParse(raw.substring(primer ? 1 : 0, tab));
    if (t == null) continue;
    final chunk = raw.substring(tab + 1);
    yield (DriveLine(t, messageType(chunk), chunk), primer);
  }
}

/// a clip's drive data, oldest first
Future<List<DriveLine>> readDriveData(File f, {bool inline = false}) {
  final path = f.path;
  return _run(() => _readLines(path), inline);
}

List<DriveLine> _readLines(String path) {
  final text = utf8.decode(gzip.decode(File(path).readAsBytesSync()), allowMalformed: true);
  return [for (final (l, _) in _parse(text)) l];
}

/// a clip's drive data played into a UIState of its own, for the overlay in the Gallery. [state]
/// is replaced by a new one on a jump (the listeners hear about it)
class DriveReplay extends ChangeNotifier {
  final List<DriveLine> lines;
  final int startMs;
  late UIState state;
  late CerealAdapter _adapter;
  int _next = 0;      // the first line not played yet
  int _at = -1;       // played up to this time (ms), -1 before the first seek
  DateTime _now;

  DriveReplay(this.lines, DateTime start)
      : startMs = start.millisecondsSinceEpoch,
        _now = start {
    _fresh();
  }

  void _fresh() {
    state = UIState()
      ..isConnected = true
      ..clock = () => _now;
    _adapter = CerealAdapter();
    _next = 0;
  }

  /// show the drive at [position] into the clip
  void seek(Duration position) {
    final target = startMs + position.inMilliseconds;
    _now = DateTime.fromMillisecondsSinceEpoch(target);
    if (_at >= 0 && target >= _at && target - _at <= _replayWarmUp.inMilliseconds) {
      _play(target);
      return;
    }
    // a little behind (the player's own position catching up with the estimate): stay put
    if (_at >= 0 && target < _at && _at - target <= _replaySlack) return;
    // a jump: a new state, given the newest message of each kind from a little before, then the rest
    _fresh();
    final warm = target - _replayWarmUp.inMilliseconds;
    var i = 0;
    final newest = <String, int>{};
    while (i < lines.length && lines[i].t <= warm) {
      if (lines[i].type.isNotEmpty) newest[lines[i].type] = i;
      i++;
    }
    for (final j in newest.values.toList()..sort()) {
      _adapter.apply(state, lines[j].chunk);
    }
    _next = i;
    _play(target);
    state.notifyNow();  // painters go by its version (live, modelV2 bumps it)
    notifyListeners();
  }

  void _play(int target) {
    while (_next < lines.length && lines[_next].t <= target) {
      _adapter.apply(state, lines[_next].chunk);
      _next++;
    }
    _at = target;
  }
}
