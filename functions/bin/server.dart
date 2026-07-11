import 'package:firebase_functions/firebase_functions.dart';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:fashion_backend_functions/flows/fitting_room_flow.dart';
import 'package:fashion_backend_functions/flows/stylist_flow.dart';

void main() {
  FirebaseApp.initializeApp();

  runFunctions((firebase) {
    // 1. Virtual Try-On callable endpoint (Dasherized name matches 'fitting-room')
    firebase.https.onCall(
      name: 'fittingRoom',
      (request, response) async {
        final auth = request.auth;
        if (auth == null) {
          throw UnauthenticatedError('User must be authenticated with Firebase Auth.');
        }

        final payload = request.data as Map<String, dynamic>;
        final flowInput = {
          'userImageBase64': payload['userImageBase64'],
          'productImageBase64': payload['productImageBase64'],
          'userId': auth.uid,
        };

        final runResult = await fittingRoomFlow.run(flowInput);
        return JsonResult(runResult.result as Map<String, dynamic>);
      },
    );

    // 2. Personal Stylist callable endpoint (Dasherized name matches 'stylist')
    firebase.https.onCall(
      name: 'stylist',
      (request, response) async {
        final auth = request.auth;
        if (auth == null) {
          throw UnauthenticatedError('User must be authenticated with Firebase Auth.');
        }

        final payload = request.data as Map<String, dynamic>;
        final flowInput = {
          'prompt': payload['prompt'],
          'userId': auth.uid,
          'sessionId': payload['sessionId'] ?? 'global_session',
          'userImageBase64': payload['userImageBase64'],
          'userImageGcsUrl': payload['userImageGcsUrl'],
        };

        final runResult = await stylistFlow.run(flowInput);
        return JsonResult(runResult.result as Map<String, dynamic>);
      },
    );
  });
}
