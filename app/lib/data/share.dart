import 'dart:typed_data';

import 'share_io.dart' if (dart.library.js_interop) 'share_web.dart' as impl;

/// Hands a picture and its text to whatever the player shares with (Discord, a chat): the phone's share
/// sheet (MainActivity "share"), or in the web app a download of the picture with the text on the
/// clipboard. Returns false when nothing could take it.
Future<bool> sharePicture(Uint8List png, String name, String text) =>
    impl.sharePicture(png, name, text);
