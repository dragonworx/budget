import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// Browser client that sends the session cookie (needed when the API is on
/// another origin; harmless same-origin).
http.Client createHttpClient() => BrowserClient()..withCredentials = true;
