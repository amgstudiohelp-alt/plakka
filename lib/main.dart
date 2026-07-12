import 'dart:async';
import 'dart:convert';
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
const _appUpdateChannel = MethodChannel('com.uygaria.plakka/app_update');
const _appPermissionsChannel = MethodChannel('com.uygaria.plakka/permissions');
const _iosAppStoreCountry = 'tr';
const _storeLookupTimeout = Duration(seconds: 6);
const _connectivityTimeout = Duration(seconds: 2);
const _connectivityRetryDelay = Duration(milliseconds: 700);
const _connectivityAttempts = 3;
const _transientReloadCooldown = Duration(seconds: 8);
const _appHeaderBackgroundColor = Color(0xFFFFFFFF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
  if (!Platform.isAndroid && !Platform.isIOS) {
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
  if (!Platform.isAndroid && !Platform.isIOS) {
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
  for (var attempt = 0; attempt < _connectivityAttempts; attempt += 1) {
    if (attempt > 0) {
      await Future<void>.delayed(_connectivityRetryDelay);
    }

    try {
      final addresses = await InternetAddress.lookup(
        _primarySiteHost,
      ).timeout(_connectivityTimeout);
      if (addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty) {
        return true;
      }
    } on Object {
      continue;
    }
  }

  return false;
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
  Uri? _lastLoadedUri;
  var _offlineCheckGeneration = 0;
  DateTime? _lastTransientReloadAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadWhenOnline());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartupPrompts());
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
    await _loadUri(controller, hasSavedSession ? _loggedInUri : _loginUri);
  }

  Future<void> _loadUri(WebViewController controller, Uri uri) async {
    _lastLoadedUri = uri;
    await controller.loadRequest(uri);
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
          _offlineCheckGeneration += 1;
          setState(() {
            _isOffline = false;
            _loadingProgress = 0;
          });
        },
        onPageFinished: (url) {
          if (!mounted) {
            return;
          }
          _offlineCheckGeneration += 1;
          final uri = Uri.tryParse(url);
          if (uri != null && _isPlakkaUri(uri)) {
            _lastLoadedUri = uri;
          }
          setState(() => _loadingProgress = 100);
          unawaited(_saveWebSessionFromUrl(url));
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) {
            return;
          }
          if (_isConnectivityError(error)) {
            unawaited(_handleMainFrameConnectivityError());
          }
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

  bool _isConnectivityError(WebResourceError error) {
    const connectivityErrorTypes = {
      WebResourceErrorType.connect,
      WebResourceErrorType.hostLookup,
      WebResourceErrorType.io,
      WebResourceErrorType.timeout,
      WebResourceErrorType.unknown,
    };

    final errorType = error.errorType;
    return errorType == null || connectivityErrorTypes.contains(errorType);
  }

  Future<void> _handleMainFrameConnectivityError() async {
    final generation = ++_offlineCheckGeneration;
    final controller = _controller;
    final isOnline = await widget.connectivityCheck();
    if (!mounted || generation != _offlineCheckGeneration) {
      return;
    }

    if (isOnline) {
      await _recoverFromTransientWebError(controller, generation);
      return;
    }

    setState(() {
      _isOffline = true;
      _loadingProgress = 0;
    });
  }

  Future<void> _recoverFromTransientWebError(
    WebViewController? controller,
    int generation,
  ) async {
    final now = DateTime.now();
    final lastReloadAt = _lastTransientReloadAt;
    if (lastReloadAt != null &&
        now.difference(lastReloadAt) < _transientReloadCooldown) {
      return;
    }

    _lastTransientReloadAt = now;
    await Future<void>.delayed(_connectivityRetryDelay);
    if (!mounted ||
        generation != _offlineCheckGeneration ||
        _controller != controller ||
        controller == null) {
      return;
    }

    await _reloadOrLoadLastKnown(controller);
  }

  Future<void> _retryCurrentPage() async {
    final controller = _controller;
    if (controller == null) {
      await _loadWhenOnline();
      return;
    }

    setState(() {
      _isCheckingConnection = true;
      _isOffline = false;
      _loadingProgress = 0;
    });
    _offlineCheckGeneration += 1;

    final isOnline = await widget.connectivityCheck();
    if (!mounted) {
      return;
    }

    if (!isOnline) {
      setState(() {
        _isCheckingConnection = false;
        _isOffline = true;
      });
      return;
    }

    setState(() => _isCheckingConnection = false);

    await _reloadOrLoadLastKnown(controller);
  }

  Future<void> _reloadOrLoadLastKnown(WebViewController controller) async {
    try {
      await controller.reload();
    } on PlatformException {
      final currentUri = await _currentPlakkaUri(controller);
      await _loadUri(controller, currentUri ?? _lastLoadedUri ?? _loginUri);
    }
  }

  Future<Uri?> _currentPlakkaUri(WebViewController controller) async {
    try {
      final currentUrl = await controller.currentUrl();
      final uri = Uri.tryParse(currentUrl ?? '');
      if (uri == null || !_isPlakkaUri(uri)) {
        return null;
      }

      return uri;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _runStartupPrompts() async {
    await _askForNotificationPermissionIfNeeded();
    await _askForInitialMediaPermissionsIfNeeded();
    await _checkForAppUpdateIfNeeded();
  }

  Future<void> _checkForAppUpdateIfNeeded() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }

    try {
      if (Platform.isAndroid) {
        await _checkAndroidStoreUpdateIfNeeded();
        return;
      }

      await _checkIosStoreUpdateIfNeeded();
    } on Object {
      return;
    }
  }

  Future<void> _checkAndroidStoreUpdateIfNeeded() async {
    final update = await _androidStoreUpdate();
    if (!mounted || !update.isAvailable) {
      return;
    }

    final shouldUpdate = await _showStoreUpdateDialog();
    if (!mounted || shouldUpdate != true) {
      return;
    }

    await _startStoreUpdate();
  }

  Future<void> _checkIosStoreUpdateIfNeeded() async {
    final installedVersion = await _installedAppVersion();
    if (installedVersion == null || installedVersion.bundleId.isEmpty) {
      return;
    }

    final storeVersion = await _fetchIosStoreVersion(installedVersion.bundleId);
    if (!mounted ||
        storeVersion == null ||
        !_isStoreVersionNewer(
          storeVersion.version,
          installedVersion.versionName,
        )) {
      return;
    }

    final shouldUpdate = await _showStoreUpdateDialog(
      version: storeVersion.version,
    );
    if (!mounted || shouldUpdate != true) {
      return;
    }

    await _openStorePage(storeVersion.storeUrl);
  }

  Future<AndroidStoreUpdate> _androidStoreUpdate() async {
    final updateInfo =
        await _appUpdateChannel.invokeMapMethod<String, dynamic>(
          'checkStoreUpdate',
        ) ??
        const <String, dynamic>{};

    return AndroidStoreUpdate.fromMap(updateInfo);
  }

  Future<InstalledAppVersion?> _installedAppVersion() async {
    final versionInfo = await _appUpdateChannel
        .invokeMapMethod<String, dynamic>('getInstalledVersion');
    if (versionInfo == null) {
      return null;
    }

    return InstalledAppVersion.fromMap(versionInfo);
  }

  Future<IosStoreVersion?> _fetchIosStoreVersion(String bundleId) async {
    final client = HttpClient();
    try {
      final lookupUri = Uri.https('itunes.apple.com', '/lookup', {
        'bundleId': bundleId,
        'country': _iosAppStoreCountry,
      });
      final request = await client
          .getUrl(lookupUri)
          .timeout(_storeLookupTimeout);
      final response = await request.close().timeout(_storeLookupTimeout);
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_storeLookupTimeout);
      final payload = jsonDecode(body);
      if (payload is! Map<String, dynamic>) {
        return null;
      }

      final results = payload['results'];
      if (results is! List || results.isEmpty) {
        return null;
      }

      for (final item in results) {
        if (item is! Map<String, dynamic>) {
          continue;
        }

        final version = item['version'] as String?;
        final storeUrl = item['trackViewUrl'] as String?;
        if (version != null &&
            version.trim().isNotEmpty &&
            storeUrl != null &&
            storeUrl.trim().isNotEmpty) {
          return IosStoreVersion(version.trim(), storeUrl.trim());
        }
      }

      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool?> _showStoreUpdateDialog({String? version}) {
    final content = version == null
        ? 'Plakka için yeni bir güncelleme yayınlandı. En iyi deneyim için '
              'uygulamayı güncelleyin.'
        : 'Plakka $version sürümü yayınlandı. En iyi deneyim için uygulamayı '
              'güncelleyin.';

    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Güncelleme mevcut'),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Daha sonra'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.system_update_alt_rounded),
              label: const Text('Güncelle'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startStoreUpdate() async {
    try {
      await _appUpdateChannel.invokeMethod<bool>('startStoreUpdate');
    } on PlatformException {
      return;
    }
  }

  Future<void> _openStorePage(String storeUrl) async {
    try {
      await _appUpdateChannel.invokeMethod<bool>('openStorePage', {
        'url': storeUrl,
      });
    } on PlatformException {
      return;
    }
  }

  Future<void> _askForNotificationPermissionIfNeeded() async {
    if ((!Platform.isAndroid && !Platform.isIOS) ||
        _oneSignalAppId.trim().isEmpty) {
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

  Future<void> _askForInitialMediaPermissionsIfNeeded() async {
    if (!Platform.isIOS) {
      return;
    }

    try {
      await _appPermissionsChannel.invokeMethod<Object?>(
        'requestInitialMediaPermissions',
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
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
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: _appHeaderBackgroundColor,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: _appHeaderBackgroundColor,
      systemNavigationBarIconBrightness: Brightness.dark,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Scaffold(
          backgroundColor: _appHeaderBackgroundColor,
          body: _buildTopSafeBody(context),
        ),
      ),
    );
  }

  Widget _buildTopSafeBody(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return Padding(
      key: const ValueKey('topSafeBodyPadding'),
      padding: EdgeInsets.only(top: mediaQuery.viewPadding.top),
      child: MediaQuery(
        data: mediaQuery.copyWith(
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.zero,
        ),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isCheckingConnection) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isOffline || _controller == null) {
      return OfflineView(onRetry: _retryCurrentPage);
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

class AndroidStoreUpdate {
  const AndroidStoreUpdate({required this.isAvailable});

  factory AndroidStoreUpdate.fromMap(Map<String, dynamic> map) {
    return AndroidStoreUpdate(isAvailable: map['available'] == true);
  }

  final bool isAvailable;
}

class InstalledAppVersion {
  const InstalledAppVersion({
    required this.bundleId,
    required this.versionName,
  });

  factory InstalledAppVersion.fromMap(Map<String, dynamic> map) {
    return InstalledAppVersion(
      bundleId: map['bundleId'] as String? ?? '',
      versionName: map['versionName'] as String? ?? '',
    );
  }

  final String bundleId;
  final String versionName;
}

class IosStoreVersion {
  const IosStoreVersion(this.version, this.storeUrl);

  final String version;
  final String storeUrl;
}

bool _isStoreVersionNewer(String storeVersion, String currentVersion) {
  if (storeVersion.trim().isEmpty || currentVersion.trim().isEmpty) {
    return false;
  }

  return _compareVersionNumbers(storeVersion, currentVersion) > 0;
}

int _compareVersionNumbers(String left, String right) {
  final leftParts = _versionParts(left);
  final rightParts = _versionParts(right);
  final maxLength = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;

  for (var index = 0; index < maxLength; index += 1) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    if (leftPart != rightPart) {
      return leftPart.compareTo(rightPart);
    }
  }

  return 0;
}

List<int> _versionParts(String version) {
  return version
      .split(RegExp(r'[^0-9]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
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
