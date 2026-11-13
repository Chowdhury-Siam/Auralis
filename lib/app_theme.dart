import 'package:flutter/material.dart';

import 'app_motion.dart';

RoundedRectangleBorder auralisSurfaceShape(
  ColorScheme colors, {
  double radius = 24,
  double borderOpacity = .55,
}) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(radius),
  side: BorderSide(
    color: colors.outlineVariant.withValues(alpha: borderOpacity),
  ),
);

OutlineInputBorder auralisFieldBorder({
  double radius = 14,
  BorderSide side = BorderSide.none,
}) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(radius),
  borderSide: side,
);

DialogThemeData auralisDialogTheme(ColorScheme colors) => DialogThemeData(
  backgroundColor: colors.surfaceContainerHigh,
  surfaceTintColor: Colors.transparent,
  shadowColor: colors.shadow.withValues(alpha: .34),
  barrierColor: colors.scrim.withValues(alpha: .64),
  elevation: 6,
  insetPadding: const EdgeInsets.all(20),
  constraints: const BoxConstraints(maxWidth: 560),
  shape: auralisSurfaceShape(colors),
);

PopupMenuThemeData auralisPopupMenuTheme(ColorScheme colors) =>
    PopupMenuThemeData(
      color: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow.withValues(alpha: .34),
      elevation: 6,
      menuPadding: const EdgeInsets.all(6),
      position: PopupMenuPosition.under,
      shape: auralisSurfaceShape(colors),
    );

ThemeData auralisTheme(ColorScheme colors) {
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );
  final buttonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(controlShape),
    foregroundBuilder: auralisButtonFeedback,
  );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: colors.surface,
  );

  return theme.copyWith(
    dialogTheme: auralisDialogTheme(colors),
    popupMenuTheme: auralisPopupMenuTheme(colors),
    appBarTheme: AppBarThemeData(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: theme.textTheme.titleLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.onPrimaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => theme.textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Icon(Icons.done_rounded, size: 17)
            : null,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: auralisSurfaceShape(colors, borderOpacity: .35),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(foregroundBuilder: auralisButtonFeedback),
    ),
    chipTheme: theme.chipTheme.copyWith(
      shape: controlShape,
      side: BorderSide(color: colors.outlineVariant),
    ),
    listTileTheme: ListTileThemeData(
      shape: controlShape,
      iconColor: colors.onSurfaceVariant,
      selectedColor: colors.onPrimaryContainer,
      selectedTileColor: colors.primaryContainer,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surfaceContainerHigh,
      border: auralisFieldBorder(),
      enabledBorder: auralisFieldBorder(),
      focusedBorder: auralisFieldBorder(
        side: BorderSide(color: colors.primary),
      ),
      errorBorder: auralisFieldBorder(side: BorderSide(color: colors.error)),
      focusedErrorBorder: auralisFieldBorder(
        side: BorderSide(color: colors.error, width: 2),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(
        color: colors.surfaceContainerHighest,
        shape: auralisSurfaceShape(colors, radius: 12),
      ),
      textStyle: theme.textTheme.bodySmall?.copyWith(color: colors.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.surfaceContainerHigh,
      contentTextStyle: theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurface,
      ),
      actionTextColor: colors.primary,
      shape: auralisSurfaceShape(colors, radius: 16),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant),
  );
}
