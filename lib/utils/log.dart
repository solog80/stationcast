import 'package:flutter/foundation.dart';

/// Logging is a no-op in release builds (avoids logcat I/O churn / heat while
/// streaming). Enabled in debug/profile.
void log(Object? message, {int? wrapWidth}) {
  if (kDebugMode) {
    debugPrint('$message', wrapWidth: wrapWidth);
  }
}
