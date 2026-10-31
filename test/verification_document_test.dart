import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/services/verification_document_picker.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9];
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

void main() {
  group('VerificationDocument', () {
    test('derives MIME and extension from JPEG/PNG signatures only', () {
      final jpeg = VerificationDocument.fromBytes(Uint8List.fromList(_jpeg));
      final png = VerificationDocument.fromBytes(Uint8List.fromList(_png));
      expect(jpeg.mimeType, 'image/jpeg');
      expect(jpeg.extension, 'jpg');
      expect(png.mimeType, 'image/png');
      expect(png.extension, 'png');
      expect(jpeg.sizeBytes, _jpeg.length);
      // Selection validates signatures, not a decoded image or its dimensions.
      expect(png.sizeBytes, _png.length);
    });

    test('copies bytes and prevents writes through every buffer view', () {
      final source = Uint8List.fromList(_jpeg);
      final document = VerificationDocument.fromBytes(source);
      source[0] = 0;
      expect(document.bytes, orderedEquals(_jpeg));
      expect(() => document.bytes[0] = 0, throwsUnsupportedError);
      expect(
        () => document.bytes.buffer.asUint8List()[0] = 0,
        throwsUnsupportedError,
      );
      expect(
        () => Uint8List.sublistView(document.bytes)[0] = 0,
        throwsUnsupportedError,
      );
      final sameData = VerificationDocument.fromBytes(
        Uint8List.fromList(_jpeg),
      );
      expect(document, isNot(sameData));
      expect(document.toString(), isNot(contains('255')));
    });

    test('allows exactly 5 MiB but rejects empty or larger data', () {
      expect(VerificationDocument.maxBytes, 5242880);
      final maximum = Uint8List(VerificationDocument.maxBytes)..setAll(0, _png);
      expect(VerificationDocument.fromBytes(maximum).sizeBytes, maximum.length);
      for (final bytes in [Uint8List(0), Uint8List(maximum.length + 1)]) {
        expect(
          () => VerificationDocument.fromBytes(bytes),
          throwsA(_failureWith('provider.errors.document_size')),
        );
      }
    });

    test('rejects unsupported and truncated or altered magic signatures', () {
      for (final bytes in <List<int>>[
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
          () => VerificationDocument.fromBytes(Uint8List.fromList(bytes)),
          throwsA(_failureWith('provider.errors.document_type')),
        );
      }
    });
  });

  group('VerificationDocumentPicker', () {
    test('cancellation succeeds with null and releases the picker', () async {
      final picker = _Picker(() async => null);
      final service = VerificationDocumentPicker(picker: picker);
      expect(await _success(service.pick()), isNull);
      expect(await _success(service.pick()), isNull);
      expect(picker.calls, 2);
      expect(
        VerificationDocumentPicker.instance,
        same(VerificationDocumentPicker.instance),
      );
    });

    test(
      'uses gallery without metadata, transforms, or trusting file hints',
      () async {
        final file = _MemoryFile(_jpeg);
        final picker = _Picker(() async => file);
        final document = await _success(
          VerificationDocumentPicker(picker: picker).pick(),
        );
        expect(document!.mimeType, 'image/jpeg');
        expect(document.extension, 'jpg');
        expect(picker.options, {
          'source': ImageSource.gallery,
          'requestFullMetadata': false,
          'maxWidth': null,
          'maxHeight': null,
          'imageQuality': null,
        });
        expect(file.calls, ['length', 'read']);
      },
    );

    test('rejects reported size before reading file bytes', () async {
      for (final length in [-1, 0, VerificationDocument.maxBytes + 1]) {
        final file = _MemoryFile(_jpeg, reportedLength: length);
        final service = VerificationDocumentPicker(
          picker: _Picker(() async => file),
        );
        expect(
          (await service.pick()).getLeft().toNullable()?.message,
          'provider.errors.document_size',
        );
        expect(file.calls, ['length']);
      }
    });

    test('checks actual bytes again after a misleading length', () async {
      final oversized = _MemoryFile(
        Uint8List(VerificationDocument.maxBytes + 1)..setAll(0, _png),
        reportedLength: 8,
      );
      final service = VerificationDocumentPicker(
        picker: _Picker(() async => oversized),
      );
      expect(
        (await service.pick()).getLeft().toNullable()?.message,
        'provider.errors.document_size',
      );
      expect(oversized.calls, ['length', 'read']);
    });

    test(
      'reports content validation without exposing the private file path',
      () async {
        final service = VerificationDocumentPicker(
          picker: _Picker(() async => _MemoryFile('not an image'.codeUnits)),
        );
        final failure = (await service.pick()).getLeft().toNullable()!;
        expect(failure.message, 'provider.errors.document_type');
        expect(failure.error, isNull);
      },
    );

    test(
      'maps platform and file failures safely and permits a later retry',
      () async {
        for (final stage in ['pick', 'length', 'read']) {
          var failOnce = true;
          final picker = _Picker(() async {
            if (stage == 'pick' && failOnce) {
              failOnce = false;
              throw PlatformException(
                code: 'photo_access_denied',
                message: 'private path',
              );
            }
            final file = _MemoryFile(_jpeg, failAt: failOnce ? stage : null);
            failOnce = false;
            return file;
          });
          final service = VerificationDocumentPicker(picker: picker);
          final failure = (await service.pick()).getLeft().toNullable()!;
          expect(failure.message, 'provider.errors.pick');
          expect(failure.error, isNull);
          expect(await _success(service.pick()), isNotNull);
        }
      },
    );

    test('concurrent selection never opens a second native picker', () async {
      final response = Completer<XFile?>();
      final picker = _Picker(() => response.future);
      final service = VerificationDocumentPicker(picker: picker);
      final first = service.pick();
      final repeated = await service.pick();
      expect(repeated.getLeft().toNullable()?.message, 'provider.errors.pick');
      expect(picker.calls, 1);
      response.complete(_MemoryFile(_png));
      expect((await _success(first))!.extension, 'png');
    });
  });
}

Matcher _failureWith(String key) =>
    isA<Failure>().having((failure) => failure.message, 'message', key);

Future<T> _success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

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
  _MemoryFile(List<int> bytes, {this.reportedLength, this.failAt})
    : bytes = Uint8List.fromList(bytes),
      super('private/evidence.pdf', mimeType: 'application/pdf');

  final Uint8List bytes;
  final int? reportedLength;
  final String? failAt;
  final calls = <String>[];

  @override
  Future<int> length() async {
    calls.add('length');
    if (failAt == 'length') throw StateError('private file length error');
    return reportedLength ?? bytes.length;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    calls.add('read');
    if (failAt == 'read') throw StateError('private file read error');
    return bytes;
  }
}
