class AppConfig {

  // Legacy ADK Backend URL.
  //
  // Default is a same-origin relative path: the Go backend serves this Flutter
  // build at `/`, so calls to `/api/...` hit the API on the same host and port.
  // Works identically on local dev, Cloud Shell Web Preview, and Cloud Run —
  // no editing needed.
  //
  // Override at build time with --dart-define=ADK_BACKEND_URL=https://your-host/api
  // if you need to point at a different backend.
  static const String adkBackendUrl = String.fromEnvironment(
    'ADK_BACKEND_URL',
    defaultValue: '/api',
  );

  // Cloud Functions / Cloud Run configuration via --dart-define.
  // You can override the project number/region directly when running against a custom GCP project:
  // e.g. `flutter run --dart-define=GCP_PROJECT_NUMBER=123456789`
  static const String gcpProjectNumber = String.fromEnvironment(
    'GCP_PROJECT_NUMBER',
    defaultValue: '1072969188690',
  );

  static const String gcpRegion = String.fromEnvironment(
    'GCP_REGION',
    defaultValue: 'us-central1',
  );

  // Endpoint for the virtual try-on (`fitting-room`) function.
  // Can be directly overridden using --dart-define=FITTING_ROOM_ENDPOINT=...
  static String get fittingRoomEndpoint {
    const overrideUrl = String.fromEnvironment('FITTING_ROOM_ENDPOINT');
    if (overrideUrl.isNotEmpty) {
      return overrideUrl;
    }
    return 'https://fitting-room-$gcpProjectNumber.$gcpRegion.run.app';
  }

  // Endpoint for the personal stylist (`stylist`) function.
  // Can be directly overridden using --dart-define=STYLIST_ENDPOINT=...
  static String get stylistEndpoint {
    const overrideUrl = String.fromEnvironment('STYLIST_ENDPOINT');
    if (overrideUrl.isNotEmpty) {
      return overrideUrl;
    }
    return 'https://stylist-$gcpProjectNumber.$gcpRegion.run.app';
  }
}
