import 'package:flutter/material.dart';

class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: const Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
  }
}
