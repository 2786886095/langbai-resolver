import 'dart:io';

String get langbaiInstanceToken =>
    Platform.environment['MEDIA_HARBOR_INSTANCE_TOKEN']?.trim() ??
    const String.fromEnvironment('LANGBAI_INSTANCE_TOKEN');
