import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// [f] off the UI thread: on a background isolate on the phone; a browser has none, so the web app runs it
/// a moment later on its one thread.
Future<T> background<T>(FutureOr<T> Function() f) =>
    kIsWeb ? Future(f) : Isolate.run(f);
