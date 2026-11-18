// "Camera + drive data": keeping the comma's messages, writing a clip's file, playing it back

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/drive_data.dart';

String car(double v) => '{"type": "carState", "data": {"vEgo": $v}}';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('drive'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('the kind of a message', () {
    expect(messageType(car(1)), 'carState');
    expect(messageType('{"type":"modelV2","data":{}}'), 'modelV2');
    expect(messageType('${car(1)}${car(2)}'), '');  // two at once
    expect(messageType('"data": {"vEgo": 1}}'), '');  // part of one
    expect(messageType('{"data": {}}'), '');
  });

  group('the log', () {
    late int now;
    late DriveDataLog log;
    setUp(() {
      now = DateTime(2026, 11, 18, 9).millisecondsSinceEpoch;
      log = DriveDataLog(Directory('${dir.path}/blocks'), nowMs: () => now, inline: true);
    });

    test('a clip gets its time, from a little before, and the rare messages from before it', () async {
      final t0 = now;
      log.add('{"type": "carParams", "data": {"wheelbase": 3.0}}');  // once, at the start
      // 40 s of carState at 10 a second, through several blocks
      for (var i = 0; i < 400; i++) {
        log.add(car(i / 10));
        now += 100;
      }
      final start = DateTime.fromMillisecondsSinceEpoch(t0 + 20000);
      final out = File('${dir.path}/clip.drive.gz');
      expect(await log.writeClip(out, start, const Duration(seconds: 10)), isTrue);
      final lines = await readDriveData(out, inline: true);
      expect(lines.first.type, 'carParams');  // from before the clip
      final from = start.millisecondsSinceEpoch - driveDataLead.inMilliseconds;
      // the newest of each kind from before, then the clip's own
      expect(lines.where((l) => l.t < from).map((l) => l.type), ['carParams', 'carState']);
      final cars = lines.where((l) => l.type == 'carState' && l.t >= from).toList();
      expect(cars.first.t, from);
      expect(cars.last.t, lessThanOrEqualTo(start.millisecondsSinceEpoch + 10500));
      expect(cars.last.t, greaterThanOrEqualTo(start.millisecondsSinceEpoch + 10000));
      expect(cars.length, 136);  // 17.0 s to 30.5 s
      // in order
      for (var i = 1; i < cars.length; i++) {
        expect(cars[i].t, greaterThan(cars[i - 1].t));
      }
    });

    test('100 a second are thinned to about 20', () async {
      for (var i = 0; i < 100; i++) {
        log.add(car(i.toDouble()));
        now += 10;
      }
      final out = File('${dir.path}/clip.drive.gz');
      expect(await log.writeClip(out, DateTime.fromMillisecondsSinceEpoch(now - 1000), const Duration(seconds: 1)), isTrue);
      final n = (await readDriveData(out, inline: true)).length;
      expect(n, inInclusiveRange(18, 23));
    });

    test('old blocks are let go, and nothing is written for a time with no messages', () async {
      log.keep = const Duration(seconds: 30);
      for (var i = 0; i < 900; i++) {
        log.add(car(i / 10));
        now += 100;
      }
      await pumpEventQueue();
      final out = File('${dir.path}/old.drive.gz');
      expect(await log.writeClip(out, DateTime.fromMillisecondsSinceEpoch(now - 80000), const Duration(seconds: 5)), isFalse);
      expect(await log.writeClip(out, DateTime.fromMillisecondsSinceEpoch(now - 10000), const Duration(seconds: 5)), isTrue);
      await log.clear();
      expect(await log.writeClip(out, DateTime.fromMillisecondsSinceEpoch(now - 10000), const Duration(seconds: 5)), isFalse);
    });
  });

  test('a clip with drive data is listed as one, and its file goes with it', () async {
    final video = File('${dir.path}/5000.mp4')..writeAsBytesSync(List.filled(1000, 0));
    driveDataFor(video).writeAsBytesSync(List.filled(200, 0));
    final store = ClipStore(dir);
    final clip = (await store.list()).single;
    expect(clip.hasDriveData, isTrue);
    expect(clip.bytes, 1200);
    expect(clip.copyWith(starred: true).hasDriveData, isTrue);
    await store.delete(clip);
    expect(driveDataFor(video).existsSync(), isFalse);
  });

  group('playing it back', () {
    final start = DateTime(2026, 11, 18, 9);
    final lines = [
      DriveLine(start.millisecondsSinceEpoch - 5000, 'liveCalibration', '{"type": "liveCalibration", "data": {"calStatus": "calibrated", "rpyCalib": [0, 0.01, 0]}}'),
      for (var i = 0; i < 100; i++) DriveLine(start.millisecondsSinceEpoch + i * 100, 'carState', car(i / 10)),
    ];

    test('follows the video forward, and starts again on a jump back', () {
      final r = DriveReplay(lines, start);
      var jumps = 0;
      r.addListener(() => jumps++);
      r.seek(Duration.zero);
      expect(r.state.isConnected, isTrue);
      expect(r.state.vEgo, 0);
      expect(r.state.calStatus, 'calibrated');  // from before the clip
      final first = r.state;
      r.seek(const Duration(milliseconds: 1500));
      expect(r.state.vEgo, 1.5);
      expect(identical(r.state, first), isTrue);
      r.seek(const Duration(milliseconds: 1300));  // a little behind: stays
      expect(r.state.vEgo, 1.5);
      r.seek(const Duration(seconds: 8));  // far ahead: started again from just before
      expect(r.state.vEgo, 8.0);
      expect(r.state.calStatus, 'calibrated');
      r.seek(const Duration(seconds: 2));
      expect(r.state.vEgo, 2.0);
      expect(identical(r.state, first), isFalse);
      expect(jumps, 3);  // the first seek, 8 s and back to 2 s
      expect(r.state.clock(), start.add(const Duration(seconds: 2)));
    });
  });
}
