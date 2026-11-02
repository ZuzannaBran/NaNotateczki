import 'package:flutter/material.dart';

import '../theme/app_typography.dart';

/// A fixed label above an outlined field, shared across account and reports.
class AppLabeledField extends StatelessWidget {
  const AppLabeledField({
    super.key,
    required this.label,
    required this.child,
    this.labelKey,
  });

  final String label;
  final Widget child;
  final Key? labelKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          key: labelKey,
          style: const TextStyle(
            fontSize: AppTypography.document,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

InputDecoration appFormFieldDecoration({Widget? suffixIcon}) {
  return InputDecoration(
    suffixIcon: suffixIcon,
    border: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    floatingLabelBehavior: FloatingLabelBehavior.never,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
  );
}
