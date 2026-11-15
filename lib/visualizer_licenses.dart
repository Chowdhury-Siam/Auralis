import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// JavaScript assets are not Pub dependencies, so register their notices here.
void registerVisualizerLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'Butterchurn 2.6.7': 'butterchurn',
      'butterchurn-presets 2.4.7': 'presets',
      'audioMotion-analyzer 4.5.4': 'audiomotion',
    }.entries) {
      final text = await rootBundle.loadString(
        'assets/visualizer/LICENSE-${entry.value}.txt',
      );
      yield LicenseEntryWithLineBreaks([entry.key], text);
    }
  });
}
