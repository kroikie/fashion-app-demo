import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:firebase_admin_sdk/auth.dart';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';

void main(List<String> args) async {
  final argParser = ArgParser()
    ..addOption('uid', abbr: 'u', help: 'Target Firebase Auth user UID.')
    ..addOption(
      'email',
      abbr: 'e',
      help: 'Target Firebase Auth user by email address.',
    )
    ..addOption(
      'claims',
      abbr: 'c',
      help:
          'JSON string of custom claims to set (e.g., \'{"admin": true, "role": "stylist"}\').',
    )
    ..addFlag(
      'clear',
      help: 'Clear existing custom user claims completely.',
      negatable: false,
    )
    ..addOption(
      'service-account',
      abbr: 's',
      help: 'Path to a service account JSON file for Admin SDK authentication.',
    )
    ..addOption(
      'project-id',
      abbr: 'p',
      help:
          'Firebase project ID (optional if specified in service account or GOOGLE_APPLICATION_CREDENTIALS).',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage help.',
    );

  try {
    final results = argParser.parse(args);

    if (results['help'] == true) {
      print('Firebase Auth Custom Claims Management CLI\n');
      print('Usage: dart run bin/set_custom_claims.dart [options]\n');
      print(argParser.usage);
      exit(0);
    }

    final uidArg = results['uid'] as String?;
    final emailArg = results['email'] as String?;

    if (uidArg == null && emailArg == null) {
      throw const FormatException(
        'You must specify either --uid (-u) or --email (-e) to identify the target user.',
      );
    }
    if (uidArg != null && emailArg != null) {
      throw const FormatException(
        'Specify either --uid (-u) or --email (-e), not both.',
      );
    }

    final serviceAccountPath = results['service-account'] as String?;
    final projectId = results['project-id'] as String?;

    AppOptions? appOptions;
    if (serviceAccountPath != null) {
      final serviceAccountFile = File(serviceAccountPath);
      if (!serviceAccountFile.existsSync()) {
        throw FormatException(
          'Service account JSON file not found at: $serviceAccountPath',
        );
      }
      appOptions = AppOptions(
        credential: Credential.fromServiceAccount(serviceAccountFile),
        projectId: projectId,
      );
    } else if (projectId != null) {
      appOptions = AppOptions(
        credential: Credential.fromApplicationDefaultCredentials(),
        projectId: projectId,
      );
    }

    final admin = FirebaseApp.initializeApp(options: appOptions);
    final auth = admin.auth();

    // Resolve user record
    UserRecord user;
    if (uidArg != null) {
      stdout.writeln('Looking up user by UID: $uidArg...');
      user = await auth.getUser(uidArg);
    } else {
      stdout.writeln('Looking up user by Email: $emailArg...');
      user = await auth.getUserByEmail(emailArg!);
    }

    stdout.writeln('Found user: ${user.uid} (Email: ${user.email ?? "N/A"})');
    stdout.writeln(
      'Current Custom Claims: ${jsonEncode(user.customClaims ?? {})}',
    );

    final clearClaims = results['clear'] == true;
    final claimsArg = results['claims'] as String?;

    if (claimsArg == null && !clearClaims) {
      stdout.writeln(
        '\nNo --claims or --clear provided. Exiting without modifying user claims.',
      );
      exit(0);
    }

    Map<String, Object?>? newClaims;
    if (claimsArg != null && clearClaims) {
      throw const FormatException(
        'Cannot pass both --claims and --clear simultaneously.',
      );
    }

    if (claimsArg != null) {
      final parsedJson = jsonDecode(claimsArg);
      if (parsedJson is! Map<String, dynamic>) {
        throw const FormatException(
          '--claims JSON must decode to a JSON object (Map).',
        );
      }
      newClaims = parsedJson.cast<String, Object?>();
    } else if (clearClaims) {
      newClaims = null;
    }

    stdout.writeln('\nUpdating custom claims for user ${user.uid}...');
    await auth.setCustomUserClaims(user.uid, customUserClaims: newClaims);

    final updatedUser = await auth.getUser(user.uid);
    stdout.writeln('SUCCESS: Custom claims updated successfully!');
    stdout.writeln(
      'New Custom Claims: ${jsonEncode(updatedUser.customClaims ?? {})}',
    );
    exit(0);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}\n');
    stderr.writeln(argParser.usage);
    exit(64); // ExitCode.usage
  } catch (e, stackTrace) {
    stderr.writeln('Fatal Error updating custom claims: $e');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
