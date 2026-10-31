import 'package:image_picker/image_picker.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/logger.dart';
import 'package:salahly/src/utils/task_runner.dart';
import 'package:salahly/src/utils/typedefs.dart';

class VerificationDocumentPicker {
  VerificationDocumentPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  static final instance = VerificationDocumentPicker();

  final ImagePicker _picker;
  bool _picking = false;

  FutureEither<VerificationDocument?> pick() {
    return runTask(() async {
      if (_picking) throw const ServerFailure('provider.errors.pick');
      _picking = true;
      try {
        // The system picker grants access to one item, not the photo library.
        final file = await _picker.pickImage(
          source: ImageSource.gallery,
          requestFullMetadata: false,
        );
        if (file == null) return null;
        final length = await file.length();
        if (length <= 0 || length > VerificationDocument.maxBytes) {
          throw const ServerFailure('provider.errors.document_size');
        }
        // Neither a filename nor a MIME hint is evidence of the file's format.
        return VerificationDocument.fromBytes(await file.readAsBytes());
      } on Failure {
        rethrow;
      } catch (_) {
        AppLogger.warning('Verification document selection failed.');
        throw const ServerFailure('provider.errors.pick');
      } finally {
        _picking = false;
      }
    });
  }
}
