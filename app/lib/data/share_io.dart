import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _app = MethodChannel('ensh/app');

/// The picture goes to the app's cache (share/, which MainActivity's FileProvider hands out), then to the
/// share sheet with the text.
Future<bool> sharePicture(Uint8List png, String name, String text) async {
  try {
    final dir = Directory('${(await getTemporaryDirectory()).path}/share');
    await dir.create(recursive: true);
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(png);
    await _app.invokeMethod('share', {'path': f.path, 'text': text});
    return true;
  } catch (_) {
    return false;
  }
}
