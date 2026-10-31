import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:salahly/src/extensions/context_extension.dart';
import 'package:salahly/src/theme/theme_constants.dart';

/// Display only when the injected repository is running in local demo mode.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, this.detail = false});

  final bool detail;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.warningContainer,
      borderRadius: AppBorders.md,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: detail
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.science_outlined,
              color: context.appColors.onWarningContainer,
              size: 20,
            ),
            SizedBox(width: AppSpacing.ms),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'common.demo_title'.tr(context: context),
                    style: context.textTheme.labelLarge?.copyWith(
                      color: context.appColors.onWarningContainer,
                    ),
                  ),
                  if (detail) ...[
                    SizedBox(height: AppSpacing.xs),
                    Text(
                      'common.demo_message'.tr(context: context),
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.appColors.onWarningContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
