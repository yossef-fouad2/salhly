import '../../imports/imports.dart';

/// The wordmark is localized; the trade mark stays recognizable in either theme.
class AppBrand extends StatelessWidget {
  const AppBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppPalettes.ink,
              borderRadius: AppBorders.md,
            ),
            child: const Icon(
              Icons.handyman_rounded,
              color: AppPalettes.amber,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'app.name'.tr(context: context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
        ),
      ],
    );
  }
}
