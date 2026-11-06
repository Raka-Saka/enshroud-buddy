import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

/// A browser has no share sheet everywhere: the picture downloads, and the text goes to the clipboard.
Future<bool> sharePicture(Uint8List png, String name, String text) async {
  try {
    final blob = web.Blob(
      [png.toJS].toJS,
      web.BlobPropertyBag(type: 'image/png'),
    );
    final url = web.URL.createObjectURL(blob);
    final a =
        web.HTMLAnchorElement()
          ..href = url
          ..download = name;
    web.document.body?.append(a);
    a.click();
    a.remove();
    web.URL.revokeObjectURL(url);
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}
