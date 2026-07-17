import 'package:flutter/material.dart';

/// Logging disabled globally to suppress all debug output.
// void log(Object? message, {int? wrapWidth}) {}

// Logging enabled globally
void log(Object? message, {int? wrapWidth}) {
  debugPrint('$message', wrapWidth: wrapWidth);
}
