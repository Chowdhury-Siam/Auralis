# Auralis integration

The public library exports the existing reference-counted `Wakelock` so Music
Lyrics and video playback can own screen-awake requests independently. Both
use the same counter and the existing Android/Windows wakelock_plus backend.
