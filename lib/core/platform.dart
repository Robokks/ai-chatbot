import 'package:flutter/foundation.dart';

bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Camera capture is only offered where image_picker supports it.
bool get hasCamera =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Physical-keyboard platforms where Enter sends and Shift+Enter adds a line.
bool get enterToSend => isDesktop || kIsWeb;
