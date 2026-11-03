import 'dart:async';

import '../../data/models/user_model.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';

/// Private, bounded, memory-only image. Never use the public network cache here.
class RequestPhotoImage extends StatefulWidget {
  const RequestPhotoImage({
    super.key,
    required this.userId,
    required this.bytes,
    required this.semanticLabel,
    this.maxDimension = 1200,
    this.fit = BoxFit.contain,
  }) : assert(maxDimension > 0 && maxDimension <= 1200);
  final String userId;
  final Uint8List bytes;
  final String semanticLabel;
  final int maxDimension;
  final BoxFit fit;

  @override
  State<RequestPhotoImage> createState() => _RequestPhotoImageState();
}

class _RequestPhotoImageState extends State<RequestPhotoImage> {
  late ImageProvider<Object> _image;
  bool _revoked = false;

  void _createImage() {
    _image = ResizeImage(
      MemoryImage(widget.bytes),
      width: widget.maxDimension,
      height: widget.maxDimension,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
  }

  @override
  void initState() {
    super.initState();
    _createImage();
  }

  @override
  void didUpdateWidget(covariant RequestPhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.maxDimension != widget.maxDimension) {
      unawaited(_image.evict());
      _createImage();
    }
  }

  @override
  void dispose() {
    unawaited(_image.evict());
    super.dispose();
  }

  bool _authorized(SessionState state) =>
      state.status == SessionStatus.authenticated &&
      state.user?.id == widget.userId &&
      state.user?.role == UserRole.customer;

  void _revoke() {
    setState(() => _revoked = true);
    unawaited(_image.evict());
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route is! PopupRoute) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route.isActive) navigator.removeRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final authorized = context.select(
      (SessionBloc bloc) => _authorized(bloc.state),
    );
    return BlocListener<SessionBloc, SessionState>(
      listenWhen: (previous, current) =>
          _authorized(previous) && !_authorized(current),
      listener: (_, _) => _revoke(),
      child: !authorized || _revoked
          ? const SizedBox.shrink()
          : Image(
              image: _image,
              fit: widget.fit,
              semanticLabel: widget.semanticLabel,
              errorBuilder: (_, _, _) =>
                  Center(child: Text('requests.errors.photo_unavailable'.tr())),
            ),
    );
  }
}
