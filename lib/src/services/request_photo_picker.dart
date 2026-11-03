import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../data/models/service_request.dart';
import '../utils/failure.dart';
import '../utils/task_runner.dart';
import '../utils/typedefs.dart';

class RequestPhotoPicker {
  RequestPhotoPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  static final instance = RequestPhotoPicker();
  final ImagePicker _picker;
  bool _picking = false;

  FutureEither<RequestPhotoInput?> pick() => runTask(() async {
    if (_picking) throw const ServerFailure('requests.errors.photo_pick');
    _picking = true;
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      final length = await file.length();
      if (length <= 0 || length > RequestPhotoInput.maxBytes) {
        throw const ServerFailure('requests.errors.photo_size');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > RequestPhotoInput.maxBytes) {
          throw const ServerFailure('requests.errors.photo_size');
        }
        bytes.add(chunk);
      }
      return RequestPhotoInput.fromBytes(bytes.takeBytes());
    } on Failure {
      rethrow;
    } catch (_) {
      throw const ServerFailure('requests.errors.photo_pick');
    } finally {
      _picking = false;
    }
  });
}
