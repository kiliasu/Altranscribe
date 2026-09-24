import 'package:material_ui/material_ui.dart';

import 'expressive.dart';

Widget pageStack(List<Widget> children, {double gap = 16}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (var i = 0; i < children.length; i++) ...[
      if (i != 0) SizedBox(height: gap),
      children[i],
    ],
  ],
);

Widget pagePanel(
  BuildContext context,
  Widget child, {
  double radius = 20,
  EdgeInsets padding = EdgeInsets.zero,
  Color? color,
}) => Material(
  color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
  borderRadius: BorderRadius.circular(radius),
  clipBehavior: Clip.antiAlias,
  child: Padding(padding: padding, child: child),
);

Widget pageColumns(
  BuildContext context,
  Widget first,
  Widget second, {
  int firstFlex = 1,
  int secondFlex = 1,
}) => MediaQuery.sizeOf(context).width < 840
    ? pageStack([first, second])
    : IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: firstFlex, child: first),
            const SizedBox(width: 16),
            Expanded(flex: secondFlex, child: second),
          ],
        ),
      );

Widget pageHint(BuildContext context, String value) => Text(
  value,
  style: Theme.of(context).textTheme.bodyMedium
      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
);

Widget pageEmptyState(
  BuildContext context,
  IconData icon,
  String title,
  String description,
  Widget action,
) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
  child: Column(
    children: [
      AltBlob(
        icon: icon,
        size: 96,
        iconSize: 44,
        background: Theme.of(context).colorScheme.secondaryContainer,
        foreground: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
      const SizedBox(height: 20),
      Text(
        title,
        style: Theme.of(context).textTheme.headlineSmall,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 12),
      action,
    ],
  ),
);
