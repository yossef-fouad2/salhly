import 'dart:typed_data';

import 'package:salahly/src/utils/failure.dart';

/// Session-only evidence. Identity equality avoids deep comparisons of image data.
final class VerificationDocument {
  const VerificationDocument._(this.bytes, this.mimeType, this.extension);

  static const maxBytes = 5242880;

  final Uint8List bytes;
  final String mimeType;
  final String extension;
  int get sizeBytes => bytes.length;

  factory VerificationDocument.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const ServerFailure('provider.errors.document_size');
    }
    final isJpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    final isPng =
        bytes.length >= pngSignature.length &&
        Iterable<int>.generate(pngSignature.length)
            .every((index) => bytes[index] == pngSignature[index]);
    if (!isJpeg && !isPng) {
      throw const ServerFailure('provider.errors.document_type');
    }
    return VerificationDocument._(
      Uint8List.fromList(bytes).asUnmodifiableView(),
      isJpeg ? 'image/jpeg' : 'image/png',
      isJpeg ? 'jpg' : 'png',
    );
  }
}
