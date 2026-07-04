import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

final _loginUri = Uri(
  scheme: 'https',
  host: 'uygaria.com',
  path: '/plakka.php',
);
final _loggedInUri = Uri(
  scheme: 'https',
  host: 'plakka.tr',
  path: '/index.php',
  queryParameters: {'m': 'logok'},
);
const _primarySiteHost = 'plakka.tr';
const _legacySiteHost = 'uygaria.com';
const _supportedSiteHosts = {_primarySiteHost, _legacySiteHost};
const _oneSignalAppId = String.fromEnvironment(
  'ONESIGNAL_APP_ID',
  defaultValue: 'eed40171-4e79-4a92-8d45-d2fa745ced03',
);
const _webSessionChannel = MethodChannel('com.uygaria.plakka/web_session');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await _initializeOneSignal();
  runApp(const PlakkaApp());
}

Future<void> _initializeOneSignal() async {
  if (_oneSignalAppId.trim().isEmpty) {
    return;
  }

  await OneSignal.initialize(_oneSignalAppId);

  final notificationConsent = await _getNotificationConsent();
  if (notificationConsent == true) {
    await OneSignal.User.pushSubscription.optIn();
  } else {
    await OneSignal.User.pushSubscription.optOut();
  }
}

Future<bool?> _getNotificationConsent() async {
  if (!Platform.isAndroid) {
    return null;
  }

  try {
    return await _webSessionChannel.invokeMethod<bool>(
      'getNotificationConsent',
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<void> _setNotificationConsent(bool allowed) async {
  if (!Platform.isAndroid) {
    return;
  }

  try {
    await _webSessionChannel.invokeMethod<void>(
      'setNotificationConsent',
      allowed,
    );
  } on MissingPluginException {
    return;
  } on PlatformException {
    return;
  }
}

Future<bool> _hasInternet() async {
  try {
    final addresses = await InternetAddress.lookup(
      _primarySiteHost,
    ).timeout(const Duration(seconds: 5));
    return addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty;
  } on Object {
    return false;
  }
}

class PlakkaApp extends StatelessWidget {
  const PlakkaApp({super.key, this.connectivityCheck = _hasInternet});

  final Future<bool> Function() connectivityCheck;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plakka',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF157A6E)),
        useMaterial3: true,
      ),
      home: PlakkaWebView(connectivityCheck: connectivityCheck),
    );
  }
}

class PlakkaWebView extends StatefulWidget {
  const PlakkaWebView({super.key, required this.connectivityCheck});

  final Future<bool> Function() connectivityCheck;

  @override
  State<PlakkaWebView> createState() => _PlakkaWebViewState();
}

class _PlakkaWebViewState extends State<PlakkaWebView>
    with WidgetsBindingObserver {
  WebViewController? _controller;
  var _isCheckingConnection = true;
  var _isOffline = false;
  var _loadingProgress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadWhenOnline());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_askForNotificationPermissionIfNeeded());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveCurrentWebSession());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveCurrentWebSession());
    }
  }

  Future<void> _loadWhenOnline() async {
    setState(() {
      _isCheckingConnection = true;
      _isOffline = false;
    });

    final isOnline = await widget.connectivityCheck();
    if (!mounted) {
      return;
    }

    if (!isOnline) {
      setState(() {
        _controller = null;
        _isCheckingConnection = false;
        _isOffline = true;
        _loadingProgress = 0;
      });
      return;
    }

    final controller = await _createWebViewController();
    setState(() {
      _controller = controller;
      _isCheckingConnection = false;
      _isOffline = false;
      _loadingProgress = 0;
    });

    final hasSavedSession = await _restoreWebSession();
    await controller.loadRequest(hasSavedSession ? _loggedInUri : _loginUri);
  }

  Future<WebViewController> _createWebViewController() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.enableZoom(false);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() => _loadingProgress = progress);
        },
        onPageStarted: (_) {
          if (!mounted) {
            return;
          }
          setState(() => _loadingProgress = 0);
        },
        onPageFinished: (url) {
          if (!mounted) {
            return;
          }
          setState(() => _loadingProgress = 100);
          unawaited(_saveWebSessionFromUrl(url));
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) {
            return;
          }
          setState(() {
            _controller = null;
            _isOffline = true;
            _loadingProgress = 0;
          });
        },
      ),
    );

    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      await platformController.enableZoom(false);
      await _allowAndroidCookies(platformController);
      await platformController.setOnShowFileSelector(_androidFilePicker);
    }

    return controller;
  }

  Future<void> _askForNotificationPermissionIfNeeded() async {
    if (!Platform.isAndroid || _oneSignalAppId.trim().isEmpty) {
      return;
    }

    final notificationConsent = await _getNotificationConsent();
    if (!mounted || notificationConsent != null) {
      return;
    }

    final allowed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Bildirimlere izin verilsin mi?'),
          content: const Text(
            'Plakka bildirimleri; hesap hareketleri, mesajlar ve önemli '
            'duyurular için kullanılır.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('İzin verme'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('İzin ver'),
            ),
          ],
        );
      },
    );

    if (!mounted || allowed == null) {
      return;
    }

    if (!allowed) {
      await _setNotificationConsent(false);
      await OneSignal.User.pushSubscription.optOut();
      return;
    }

    var permissionGranted = OneSignal.Notifications.permission;
    if (await OneSignal.Notifications.canRequest()) {
      permissionGranted = await OneSignal.Notifications.requestPermission(
        false,
      );
    }

    await _setNotificationConsent(permissionGranted);
    if (permissionGranted) {
      await OneSignal.User.pushSubscription.optIn();
    } else {
      await OneSignal.User.pushSubscription.optOut();
    }
  }

  Future<void> _allowAndroidCookies(AndroidWebViewController controller) async {
    final cookieManager = WebViewCookieManager().platform;
    if (cookieManager is AndroidWebViewCookieManager) {
      await cookieManager.setAcceptThirdPartyCookies(controller, true);
    }
  }

  Future<bool> _restoreWebSession() {
    return _invokeWebSessionMethod('restoreCookies', _loggedInUri);
  }

  Future<void> _saveCurrentWebSession() async {
    try {
      final currentUrl = await _controller?.currentUrl();
      await _saveWebSessionFromUrl(currentUrl);
    } on PlatformException {
      return;
    }
  }

  Future<void> _saveWebSessionFromUrl(String? url) {
    final uri = Uri.tryParse(url ?? '') ?? _loginUri;
    return _saveWebSession(uri);
  }

  Future<void> _saveWebSession(Uri uri) {
    if (!_isPlakkaUri(uri)) {
      return Future<void>.value();
    }

    return _invokeWebSessionMethod('saveCookies', uri).then((_) {});
  }

  bool _isPlakkaUri(Uri uri) {
    if (uri.scheme != 'https') {
      return false;
    }

    return _supportedSiteHosts.any(
      (host) => uri.host == host || uri.host.endsWith('.$host'),
    );
  }

  Future<bool> _invokeWebSessionMethod(String method, Uri uri) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }

    try {
      return await _webSessionChannel.invokeMethod<bool>(
            method,
            uri.toString(),
          ) ??
          false;
    } on MissingPluginException {
      // Mobile builds register this channel. Tests and desktop builds can skip it.
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<String>> _androidFilePicker(FileSelectorParams params) async {
    final pickerOptions = _pickerOptionsFor(params.acceptTypes);
    final result = await FilePicker.pickFiles(
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
      type: pickerOptions.type,
      allowedExtensions: pickerOptions.allowedExtensions,
    );

    final files = result?.files ?? const <PlatformFile>[];
    return files
        .map((file) => file.path)
        .whereType<String>()
        .map((path) => Uri.file(path).toString())
        .toList();
  }

  PickerOptions _pickerOptionsFor(List<String> acceptTypes) {
    final normalized = acceptTypes
        .map((type) => type.trim().toLowerCase())
        .where((type) => type.isNotEmpty)
        .toList();

    if (normalized.isEmpty) {
      return const PickerOptions(FileType.any);
    }

    if (normalized.every(
      (type) => type == 'image/*' || type.startsWith('image/'),
    )) {
      return const PickerOptions(FileType.image);
    }

    if (normalized.every(
      (type) => type == 'video/*' || type.startsWith('video/'),
    )) {
      return const PickerOptions(FileType.video);
    }

    if (normalized.every(
      (type) => type == 'audio/*' || type.startsWith('audio/'),
    )) {
      return const PickerOptions(FileType.audio);
    }

    final extensions = normalized
        .where((type) => type.startsWith('.'))
        .map((type) => type.substring(1))
        .where((extension) => extension.isNotEmpty)
        .toList();

    if (extensions.isNotEmpty) {
      return PickerOptions(FileType.custom, extensions);
    }

    return const PickerOptions(FileType.any);
  }

  Future<void> _handleBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }

    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Scaffold(
        body: SafeArea(top: false, bottom: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_isCheckingConnection) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isOffline || _controller == null) {
      return OfflineView(onRetry: _loadWhenOnline);
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_loadingProgress < 100)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _loadingProgress == 0 ? null : _loadingProgress / 100,
            ),
          ),
      ],
    );
  }
}

class PickerOptions {
  const PickerOptions(this.type, [this.allowedExtensions]);

  final FileType type;
  final List<String>? allowedExtensions;
}

class OfflineView extends StatelessWidget {
  const OfflineView({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: colors.surface,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: 52, color: colors.primary),
          const SizedBox(height: 18),
          Text(
            'Internet baglantisi yok',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Plakka acilmak icin internet baglantisi gerektirir.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }
}
