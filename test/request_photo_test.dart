import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/services/request_photo_picker.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

const _photoId = '44444444-4444-4444-8444-444444444444';
const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9];
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

void main() {
  group('RequestPhotoInput', () {
    test('detects JPEG and PNG signatures and assigns stable UUIDv4 IDs', () {
      final jpeg = RequestPhotoInput.fromBytes(Uint8List.fromList(_jpeg));
      final png = RequestPhotoInput.fromBytes(Uint8List.fromList(_png));
      expect(jpeg.mimeType, 'image/jpeg');
      expect(jpeg.extension, 'jpg');
      expect(jpeg.sizeBytes, _jpeg.length);
      expect(png.mimeType, 'image/png');
      expect(png.extension, 'png');
      expect(png.sizeBytes, _png.length);
      expect(ServiceRequestDraft.validId(jpeg.id), isTrue);
      expect(ServiceRequestDraft.validId(png.id), isTrue);
      expect(jpeg.id, isNot(png.id));
      final restored = RequestPhotoInput.fromBytes(
        Uint8List.fromList(_jpeg),
        id: jpeg.id,
      );
      expect(restored.id, jpeg.id);
      expect(restored, isNot(jpeg));
    });

    test('rejects noncanonical, non-v4, and path-like photo IDs', () {
      for (final id in [
        '',
        ' $_photoId',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase(),
        '44444444-4444-1444-8444-444444444444',
        '44444444-4444-4444-7444-444444444444',
        '../$_photoId',
        'https://example.test/$_photoId',
      ]) {
        expect(
          () => RequestPhotoInput.fromBytes(Uint8List.fromList(_jpeg), id: id),
          throwsA(_failureWith('requests.errors.photos')),
          reason: id,
        );
      }
      expect(
        RequestPhotoInput.fromBytes(Uint8List.fromList(_jpeg), id: _photoId).id,
        _photoId,
      );
    });

    test(
      'copies input bytes and prevents mutation through all buffer views',
      () {
        final source = Uint8List.fromList(_jpeg);
        final photo = RequestPhotoInput.fromBytes(source, id: _photoId);
        source.fillRange(0, source.length, 0);
        expect(photo.bytes, orderedEquals(_jpeg));
        expect(() => photo.bytes[0] = 0, throwsUnsupportedError);
        expect(
          () => photo.bytes.buffer.asUint8List()[0] = 0,
          throwsUnsupportedError,
        );
        expect(
          () => Uint8List.sublistView(photo.bytes)[0] = 0,
          throwsUnsupportedError,
        );
        expect(
          () => ByteData.view(photo.bytes.buffer).setUint8(0, 0),
          throwsUnsupportedError,
        );
        expect(photo.toString(), isNot(contains(_photoId)));
        expect(photo.toString(), isNot(contains('255')));
      },
    );

    test(
      'allows exactly 5 MiB per JPEG or PNG but not empty or larger input',
      () {
        expect(RequestPhotoInput.maxBytes, 5 * 1024 * 1024);
        for (final signature in [_jpeg, _png]) {
          final maximum = Uint8List(RequestPhotoInput.maxBytes)
            ..setAll(0, signature);
          expect(
            RequestPhotoInput.fromBytes(maximum).sizeBytes,
            RequestPhotoInput.maxBytes,
          );
        }
        for (final bytes in [
          Uint8List(0),
          Uint8List(RequestPhotoInput.maxBytes + 1)..setAll(0, _jpeg),
        ]) {
          expect(
            () => RequestPhotoInput.fromBytes(bytes),
            throwsA(_failureWith('requests.errors.photo_size')),
          );
        }
      },
    );

    test('rejects unsupported, truncated, and altered magic signatures', () {
      for (final bytes in <List<int>>[
        [0xff],
        [0xff, 0xd8],
        [0xff, 0xd8, 0x00],
        _png.sublist(0, 7),
        [..._png.take(7), 0x00],
        'GIF89a'.codeUnits,
        '%PDF-1.7'.codeUnits,
        'RIFF....WEBP'.codeUnits,
        '....ftypheic'.codeUnits,
      ]) {
        expect(
          () => RequestPhotoInput.fromBytes(Uint8List.fromList(bytes)),
          throwsA(_failureWith('requests.errors.photo_type')),
        );
      }
    });
  });

  group('RequestPhotoPicker', () {
    test('gallery cancellation returns null and releases the picker', () async {
      final picker = _Picker(() async => null);
      final service = RequestPhotoPicker(picker: picker);
      expect(await _success(service.pick()), isNull);
      expect(await _success(service.pick()), isNull);
      expect(picker.calls, 2);
      expect(RequestPhotoPicker.instance, same(RequestPhotoPicker.instance));
    });

    test(
      'streams gallery bytes without metadata or trusting filename/MIME',
      () async {
        for (final signature in [_jpeg, _png]) {
          final file = _MemoryFile(signature, chunkSize: 2);
          final picker = _Picker(() async => file);
          final photo = await _success(
            RequestPhotoPicker(picker: picker).pick(),
          );
          expect(photo!.bytes, orderedEquals(signature));
          expect(
            photo.mimeType,
            signature == _jpeg ? 'image/jpeg' : 'image/png',
          );
          expect(photo.extension, signature == _jpeg ? 'jpg' : 'png');
          expect(ServiceRequestDraft.validId(photo.id), isTrue);
          expect(picker.options, {
            'source': ImageSource.gallery,
            'requestFullMetadata': false,
            'maxWidth': null,
            'maxHeight': null,
            'imageQuality': null,
          });
          expect(file.calls, ['length', 'stream']);
          expect(file.chunksRead, 4);
          expect(file.streamClosed, isTrue);
          file.bytes[0] = 0;
          expect(photo.bytes, orderedEquals(signature));
          expect(() => photo.bytes[0] = 0, throwsUnsupportedError);
        }
      },
    );

    test(
      'rejects invalid reported sizes without opening the byte stream',
      () async {
        for (final length in [-1, 0, RequestPhotoInput.maxBytes + 1]) {
          final file = _MemoryFile(_jpeg, reportedLength: length);
          await _expectFailure(
            RequestPhotoPicker(picker: _Picker(() async => file)).pick(),
            'requests.errors.photo_size',
          );
          expect(file.calls, ['length']);
          expect(file.chunksRead, 0);
        }
      },
    );

    test('accepts an exactly 5 MiB stream at the inclusive boundary', () async {
      final file = _MemoryFile(
        Uint8List(RequestPhotoInput.maxBytes)..setAll(0, _png),
        chunkSize: 64 * 1024,
      );
      final photo = await _success(
        RequestPhotoPicker(picker: _Picker(() async => file)).pick(),
      );
      expect(photo!.sizeBytes, RequestPhotoInput.maxBytes);
      expect(photo.mimeType, 'image/png');
      expect(file.chunksRead, 80);
      expect(file.streamClosed, isTrue);
    });

    test(
      'caps actual streamed bytes and cancels before reading remaining chunks',
      () async {
        const chunkSize = 1024 * 1024;
        final file = _MemoryFile(
          Uint8List(RequestPhotoInput.maxBytes + 2 * chunkSize)
            ..setAll(0, _jpeg),
          reportedLength: _jpeg.length,
          chunkSize: chunkSize,
        );
        await _expectFailure(
          RequestPhotoPicker(picker: _Picker(() async => file)).pick(),
          'requests.errors.photo_size',
        );
        expect(file.calls, ['length', 'stream']);
        expect(file.chunksRead, 6);
        expect(file.streamClosed, isTrue);
      },
    );

    test(
      'validates actual empty and unsupported bytes after a valid length',
      () async {
        for (final (bytes, key) in <(List<int>, String)>[
          ([], 'requests.errors.photo_size'),
          ('not an image'.codeUnits, 'requests.errors.photo_type'),
        ]) {
          final file = _MemoryFile(bytes, reportedLength: 8);
          final failure = await _expectFailure(
            RequestPhotoPicker(picker: _Picker(() async => file)).pick(),
            key,
          );
          expect(failure.error, isNull);
          expect(failure.toString(), isNot(contains('private')));
          expect(file.streamClosed, isTrue);
        }
      },
    );

    for (final stage in ['pick', 'length', 'stream']) {
      test(
        '$stage failure is sanitized and does not block a later pick',
        () async {
          var failOnce = true;
          final picker = _Picker(() async {
            final shouldFail = failOnce;
            failOnce = false;
            if (shouldFail && stage == 'pick') {
              throw PlatformException(
                code: 'photo_access_denied',
                message: 'private file path',
              );
            }
            return _MemoryFile(_jpeg, failAt: shouldFail ? stage : null);
          });
          final service = RequestPhotoPicker(picker: picker);
          final failure = await _expectFailure(
            service.pick(),
            'requests.errors.photo_pick',
          );
          expect(failure.error, isNull);
          expect((await _success(service.pick()))!.bytes, orderedEquals(_jpeg));
          expect(picker.calls, 2);
        },
      );
    }

    test(
      'concurrent picks stay blocked through selection and stream reading',
      () async {
        final selection = Completer<XFile?>();
        final readStarted = Completer<void>();
        final readGate = Completer<void>();
        var firstSelection = true;
        final picker = _Picker(() {
          if (firstSelection) {
            firstSelection = false;
            return selection.future;
          }
          return Future.value(null);
        });
        final service = RequestPhotoPicker(picker: picker);
        final first = service.pick();
        await _expectFailure(service.pick(), 'requests.errors.photo_pick');
        expect(picker.calls, 1);
        selection.complete(
          _MemoryFile(_png, readStarted: readStarted, readGate: readGate),
        );
        await readStarted.future;
        await _expectFailure(service.pick(), 'requests.errors.photo_pick');
        expect(picker.calls, 1);
        readGate.complete();
        expect((await _success(first))!.extension, 'png');
        expect(await _success(service.pick()), isNull);
        expect(picker.calls, 2);
      },
    );
  });
}

Matcher _failureWith(String key) =>
    isA<Failure>().having((failure) => failure.message, 'message', key);

Future<T> _success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

Future<Failure> _expectFailure<T>(FutureEither<T> task, String key) async {
  final failure = (await task).fold(
    (failure) => failure,
    (_) => fail('Expected $key'),
  );
  expect(failure.message, key);
  return failure;
}

class _Picker extends ImagePicker {
  _Picker(this.response);

  final Future<XFile?> Function() response;
  int calls = 0;
  Map<String, Object?>? options;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) {
    calls++;
    options = {
      'source': source,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'imageQuality': imageQuality,
      'requestFullMetadata': requestFullMetadata,
    };
    return response();
  }
}

class _MemoryFile extends XFile {
  _MemoryFile(
    List<int> bytes, {
    this.reportedLength,
    this.failAt,
    this.chunkSize = 64 * 1024,
    this.readStarted,
    this.readGate,
  }) : bytes = Uint8List.fromList(bytes),
       super('private/request-photo.pdf', mimeType: 'application/pdf');

  final Uint8List bytes;
  final int? reportedLength;
  final String? failAt;
  final int chunkSize;
  final Completer<void>? readStarted;
  final Completer<void>? readGate;
  final calls = <String>[];
  int chunksRead = 0;
  bool streamClosed = false;

  @override
  Future<int> length() async {
    calls.add('length');
    if (failAt == 'length') throw StateError('private file length error');
    return reportedLength ?? bytes.length;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    calls.add('whole-file');
    throw StateError('Unbounded whole-file reads are forbidden in this test.');
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    calls.add('stream');
    try {
      readStarted?.complete();
      if (readGate != null) await readGate!.future;
      if (failAt == 'stream') throw StateError('private file stream error');
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        chunksRead++;
        yield Uint8List.sublistView(bytes, offset, end);
      }
    } finally {
      streamClosed = true;
    }
  }
}
