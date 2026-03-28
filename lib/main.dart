import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/app_user.dart';
import 'models/call_models.dart';
import 'models/chat_message.dart';
import 'models/chat_message_content.dart';
import 'services/auth_service.dart';
import 'services/app_notification_service.dart';
import 'services/app_update_service.dart';
import 'services/app_window_service.dart';
import 'services/backchat_api_service.dart';
import 'services/call_service.dart';
import 'services/conversation_background_service.dart';
import 'services/conversation_session_service.dart';
import 'services/contacts_service.dart';
import 'services/encryption_service.dart';
import 'services/giphy_service.dart';
import 'services/keyboard_media_service.dart';
import 'services/media_attachment_service.dart';
import 'services/messaging_service.dart';
import 'widgets/giphy_picker_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BackchatApp());
}

class BackchatApp extends StatelessWidget {
  const BackchatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Backchat',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const BackchatHomePage(),
    );
  }
}

class _ConversationEntry {
  const _ConversationEntry({
    required this.message,
    required this.content,
  });

  final ChatMessage message;
  final ChatMessageContent content;
}

enum _CallAudioCueMode {
  none,
  incomingRinging,
  outgoingDialing,
}

enum _SessionMenuAction {
  editProfile,
  callSettings,
  setStatusOnline,
  setStatusBusy,
  setStatusOffline,
  signOut,
}

enum _ComposerAttachmentAction {
  sticker,
  gif,
  image,
  background,
  video,
  audio,
  file,
}

class _StickerPreset {
  const _StickerPreset({
    required this.emoji,
    required this.label,
  });

  final String emoji;
  final String label;
}

class BackchatHomePage extends StatefulWidget {
  const BackchatHomePage({super.key});

  @override
  State<BackchatHomePage> createState() => _BackchatHomePageState();
}

class _BackchatHomePageState extends State<BackchatHomePage>
    with TrayListener, WidgetsBindingObserver {
  static const double _compactChatBreakpoint = 760;
  static const Duration _messagePollInterval = Duration(seconds: 1);
  static const Duration _contactRefreshInterval = Duration(seconds: 8);
  static const Duration _updateCheckInterval = Duration(minutes: 30);
  static const String _plainTextTransportMode = 'plaintext_v1';
  static const List<_StickerPreset> _stickerPresets = <_StickerPreset>[
    _StickerPreset(emoji: '😀', label: 'Smile'),
    _StickerPreset(emoji: '😂', label: 'Laugh'),
    _StickerPreset(emoji: '😍', label: 'Love'),
    _StickerPreset(emoji: '🎉', label: 'Celebrate'),
    _StickerPreset(emoji: '🔥', label: 'Fire'),
    _StickerPreset(emoji: '👍', label: 'Approve'),
    _StickerPreset(emoji: '👀', label: 'Look'),
    _StickerPreset(emoji: '💯', label: 'Perfect'),
  ];

  final AuthService _authService = AuthService();
  final ContactsService _contactsService = ContactsService();
  final EncryptionService _encryptionService = EncryptionService();
  final MessagingService _messagingService = MessagingService();
  final AppNotificationService _appNotificationService =
      AppNotificationService();
  final AppUpdateService _appUpdateService = AppUpdateService();
  final AppWindowService _appWindowService = AppWindowService();
  final ConversationBackgroundService _conversationBackgroundService =
      ConversationBackgroundService();
  final ConversationSessionService _conversationSessionService =
      ConversationSessionService();
  final CallService _callService = CallService();
  final GiphyService _giphyService = GiphyService();
  final KeyboardMediaService _keyboardMediaService = KeyboardMediaService();
  final MediaAttachmentService _mediaAttachmentService =
      MediaAttachmentService();
  final BackchatApiClient _profileApi = BackchatApiService();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _conversationScrollController = ScrollController();

  AppUser? _currentUser;
  List<AppUser> _contacts = <AppUser>[];
  AppUser? _selectedContact;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _usernameRecoveryEmailController =
      TextEditingController();
  final TextEditingController _recoveryEmailController =
      TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _inviteUsernameController =
      TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final List<_ConversationEntry> _conversation = <_ConversationEntry>[];
  List<RememberedUsernameAccount> _rememberedAccounts =
      <RememberedUsernameAccount>[];
  String? _rememberedAccountSelection;
  bool _obscurePassword = true;
  bool _isAuthBusy = false;
  bool _isInviteBusy = false;
  bool _isSyncingMessages = false;
  bool _isLoadingContacts = false;
  bool _isRecoveringSession = false;
  bool _hasCheckedStartupUpdate = false;
  bool _isCheckingStartupUpdate = false;
  bool _retryStartupUpdateOnResume = false;
  bool _isShowingStartupUpdateDialog = false;
  Timer? _messagePollTimer;
  Timer? _contactRefreshTimer;
  Timer? _updateCheckTimer;
  Timer? _callAudioCueTimer;
  _CallAudioCueMode _callAudioCueMode = _CallAudioCueMode.none;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  ActiveCallState _lastCallState = ActiveCallState.idle;
  String? _selectedConversationBackgroundUrl;
  DateTime? _lastUpdateCheckAt;
  AppUpdateCheckResult? _availableUpdate;
  String? _notifiedUpdateKey;
  String? _shownUpdateDialogKey;
  bool _isDraggingVisualMedia = false;

  SecretKey? _sharedSecret;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageFocusNode.addListener(_handleMessageComposerFocusChanged);
    _callService.addListener(_handleCallServiceChanged);
    _bootstrapCrypto();
    _configureTrayIfDesktop();
    unawaited(_appNotificationService.cancelIncomingCallNotification());
    unawaited(_appNotificationService.cancelUpdateNotification());
    _loadRememberedAccounts(autofillSingleAccount: true);
    _startUpdatePolling();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForStartupUpdate(startupOnly: true));
    });
    unawaited(_restoreSessionIfPossible());
  }

  @override
  void dispose() {
    _stopMessagePolling();
    _stopContactRefresh();
    _stopUpdatePolling();
    _stopCallAudioCue();
    WidgetsBinding.instance.removeObserver(this);
    _messageFocusNode.removeListener(_handleMessageComposerFocusChanged);
    _callService.removeListener(_handleCallServiceChanged);
    _callService.dispose();
    _usernameController.dispose();
    _usernameRecoveryEmailController.dispose();
    _recoveryEmailController.dispose();
    _passwordController.dispose();
    _inviteUsernameController.dispose();
    _messageController.dispose();
    _messageFocusNode.dispose();
    _conversationScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _shownUpdateDialogKey = null;
      unawaited(_appNotificationService.cancelIncomingCallNotification());
      unawaited(_handleAppResumed());
      if (_retryStartupUpdateOnResume) {
        unawaited(_attemptSelectedUpdate());
      } else if (_availableUpdate != null) {
        unawaited(_announceAvailableUpdate(_availableUpdate!));
      } else {
        unawaited(_checkForStartupUpdate());
      }
    } else {
      _shownUpdateDialogKey = null;
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_messageFocusNode.hasFocus) {
      _revealLatestMessagesForReply();
    }
  }

  void _handleCallServiceChanged() {
    if (!mounted) {
      return;
    }

    final ActiveCallState callState = _callService.state;
    final ActiveCallState previousCallState = _lastCallState;
    final AppUser? peer = callState.peer;
    if (peer != null) {
      final int contactIndex =
          _contacts.indexWhere((AppUser contact) => contact.id == peer.id);
      if (contactIndex >= 0) {
        final AppUser mergedContact = _contacts[contactIndex].copyWith(
          displayName: peer.displayName,
          avatarUrl: peer.avatarUrl,
          username: peer.username.isNotEmpty
              ? peer.username
              : _contacts[contactIndex].username,
          quote: peer.quote,
        );
        _contacts[contactIndex] = mergedContact;
        if (callState.isIncoming || callState.isInProgress) {
          _selectedContact = mergedContact;
          unawaited(_rememberSelectedConversation(mergedContact));
        }
      }
    }
    _syncCallAudioCue(callState);
    unawaited(
      _syncCallNotification(
        previousState: previousCallState,
        nextState: callState,
      ),
    );
    _lastCallState = callState;
    setState(() {});
  }

  void _handleMessageComposerFocusChanged() {
    if (_messageFocusNode.hasFocus) {
      _revealLatestMessagesForReply();
    }
  }

  bool _useCompactChatLayout(BuildContext context) {
    return MediaQuery.sizeOf(context).width < _compactChatBreakpoint;
  }

  void _closeMobileConversation() {
    if (_selectedContact == null) {
      return;
    }
    setState(() {
      _selectedContact = null;
      _conversation.clear();
    });
    unawaited(_rememberSelectedConversation(null));
  }

  Future<void> _signOutCurrentUser() async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null || _isAuthBusy) {
      return;
    }

    setState(() {
      _isAuthBusy = true;
    });

    try {
      if (!_callService.state.isIdle) {
        await _callService.endCall();
      } else {
        await _callService.clearEndedState();
      }
      await _authService.signOut(currentUser);
      _stopMessagePolling();
      _stopContactRefresh();
      _messagingService.reset();
      await _callService.deactivate();
      await _appNotificationService.cancelAllNotifications();

      if (!mounted) {
        return;
      }

      setState(() {
        _currentUser = null;
        _contacts = <AppUser>[];
        _selectedContact = null;
        _selectedConversationBackgroundUrl = null;
        _conversation.clear();
      });

      await _syncWindowUnreadCount();
      await _loadRememberedAccounts();
      _showAuthMessage('Signed out.');
    } catch (_) {
      _showAuthMessage('Could not sign out right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isAuthBusy = false;
        });
      }
    }
  }

  void _syncCallAudioCue(ActiveCallState callState) {
    final _CallAudioCueMode nextMode = switch (callState.lifecycle) {
      CallLifecycle.incomingRinging => _CallAudioCueMode.incomingRinging,
      CallLifecycle.outgoingRinging => _CallAudioCueMode.outgoingDialing,
      CallLifecycle.connecting when callState.isInitiator =>
        _CallAudioCueMode.outgoingDialing,
      _ => _CallAudioCueMode.none,
    };

    if (nextMode == _callAudioCueMode) {
      return;
    }

    _stopCallAudioCue();
    _callAudioCueMode = nextMode;
    switch (nextMode) {
      case _CallAudioCueMode.none:
        return;
      case _CallAudioCueMode.incomingRinging:
        unawaited(_playIncomingCallCueBurst());
        _callAudioCueTimer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(_playIncomingCallCueBurst()),
        );
        return;
      case _CallAudioCueMode.outgoingDialing:
        unawaited(_playOutgoingCallCueBurst());
        _callAudioCueTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_playOutgoingCallCueBurst()),
        );
        return;
    }
  }

  void _stopCallAudioCue() {
    _callAudioCueTimer?.cancel();
    _callAudioCueTimer = null;
    _callAudioCueMode = _CallAudioCueMode.none;
  }

  Future<void> _playIncomingCallCueBurst() async {
    if (kIsWeb) {
      return;
    }
    await _playCallAlertCue();
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await HapticFeedback.mediumImpact();
      } catch (_) {
        // Ignore unsupported haptics on the current device.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _playCallAlertCue();
  }

  Future<void> _playOutgoingCallCueBurst() async {
    if (kIsWeb) {
      return;
    }
    await _playCallAlertCue();
  }

  Future<void> _playCallAlertCue() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // Some desktop embedders do not implement system sound playback.
    }
  }

  Future<void> _bootstrapCrypto() async {
    final SimpleKeyPair localKeyPair =
        await _encryptionService.createIdentityKeyPair();
    final SimpleKeyPair remotePair =
        await _encryptionService.createIdentityKeyPair();
    final SimplePublicKey remotePublicKey = await remotePair.extractPublicKey();

    _sharedSecret = await _encryptionService.deriveSharedSecret(
      localPrivateKey: localKeyPair,
      remotePublicKey: remotePublicKey,
    );
  }

  Future<void> _configureTrayIfDesktop() async {
    if (kIsWeb ||
        !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return;
    }

    trayManager.addListener(this);
    await trayManager.setToolTip('Backchat');
    await trayManager.setContextMenu(Menu(items: <MenuItem>[
      MenuItem(key: 'show', label: 'Show Backchat'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  }

  @override
  void onTrayIconMouseDown() {
    // Hook window show/hide in production with window_manager.
  }

  Future<void> _loadContacts() async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null || _isLoadingContacts) {
      return;
    }

    _isLoadingContacts = true;
    try {
      final String? previousSelectedId = _selectedContact?.id;
      final List<AppUser> contacts =
          await _contactsService.pullContactsFor(currentUser);

      AppUser? selectedContact;
      if (previousSelectedId != null) {
        for (final AppUser contact in contacts) {
          if (contact.id == previousSelectedId) {
            selectedContact = contact;
            break;
          }
        }
      }
      if (!mounted) {
        return;
      }

      setState(() {
        _contacts = contacts;
        _selectedContact = selectedContact;
      });
      await _refreshConversation();
      await _syncWindowUnreadCount();
    } finally {
      _isLoadingContacts = false;
    }
  }

  void _showAuthMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadRememberedAccounts({
    bool autofillSingleAccount = false,
  }) async {
    final List<RememberedUsernameAccount> accounts =
        await _authService.loadRememberedUsernameAccounts();
    if (!mounted) {
      return;
    }

    final String normalizedUsername =
        _usernameController.text.trim().toLowerCase();
    final String? nextSelection = accounts.any(
      (RememberedUsernameAccount account) =>
          account.normalizedUsername == normalizedUsername,
    )
        ? normalizedUsername
        : null;

    setState(() {
      _rememberedAccounts = accounts;
      _rememberedAccountSelection = nextSelection;
    });

    if (autofillSingleAccount &&
        accounts.length == 1 &&
        _usernameController.text.trim().isEmpty &&
        _usernameRecoveryEmailController.text.trim().isEmpty) {
      _applyRememberedAccount(accounts.first);
    }
  }

  void _applyRememberedAccount(RememberedUsernameAccount account) {
    _usernameController.text = account.username;
    _usernameRecoveryEmailController.text = account.recoveryEmail;
    _recoveryEmailController.text = account.recoveryEmail;
    setState(() {
      _rememberedAccountSelection = account.normalizedUsername;
    });
  }

  Future<void> _activateUserSession(AppUser user) async {
    _stopMessagePolling();
    _stopContactRefresh();
    await _appNotificationService.cancelIncomingCallNotification();
    await _authService.rememberAuthenticatedUser(user);
    await _messagingService.activateForUser(user.id);
    await _callService.activateForUser(user);

    if (!mounted) {
      return;
    }

    setState(() {
      _currentUser = user;
      _contacts = <AppUser>[];
      _selectedContact = null;
      _selectedConversationBackgroundUrl = null;
      _conversation.clear();
    });

    await _appNotificationService.requestPermissionIfNeeded();
    await _loadContacts();
    await _restoreLastConversationSelection();
    _startMessagePolling();
    _startContactRefresh();
    await _syncMessages(showErrors: false);
    await _syncWindowUnreadCount();
  }

  Future<void> _restoreSessionIfPossible() async {
    if (_currentUser != null || _isRecoveringSession) {
      return;
    }

    _isRecoveringSession = true;
    try {
      final AppUser? resumedOAuthUser =
          await _authService.tryResumePendingSocialSignIn();
      if (resumedOAuthUser != null && mounted) {
        await _activateUserSession(resumedOAuthUser);
        return;
      }

      final AppUser? restoredUser =
          await _authService.tryRestoreAuthenticatedUser();
      if (restoredUser != null && mounted) {
        await _activateUserSession(restoredUser);
      }
    } finally {
      _isRecoveringSession = false;
    }
  }

  Future<void> _handleAppResumed() async {
    await _restoreSessionIfPossible();

    final AppUser? currentUser = _currentUser;
    if (currentUser == null) {
      return;
    }

    _startMessagePolling();
    _startContactRefresh();
    await _callService.resumeForeground();
    await _loadContacts();
    await _syncMessages(showErrors: false);
  }

  Future<void> _checkForStartupUpdate({
    bool startupOnly = false,
    bool forceRetry = false,
  }) async {
    if (_isCheckingStartupUpdate) {
      return;
    }
    if (startupOnly && _hasCheckedStartupUpdate && !forceRetry) {
      return;
    }
    if (!forceRetry && !startupOnly && !_shouldRunUpdateCheckNow()) {
      return;
    }

    if (startupOnly) {
      _hasCheckedStartupUpdate = true;
    }
    _isCheckingStartupUpdate = true;
    _lastUpdateCheckAt = DateTime.now();
    try {
      final AppUpdateCheckResult result =
          await _appUpdateService.checkForStartupUpdate(startInstall: false);
      if (!mounted) {
        return;
      }

      switch (result.status) {
        case AppUpdateStatus.manualUpdateAvailable:
          _availableUpdate = result;
          await _announceAvailableUpdate(result);
          break;
        case AppUpdateStatus.upToDate:
          _availableUpdate = null;
          _notifiedUpdateKey = null;
          await _appNotificationService.cancelUpdateNotification();
          break;
        case AppUpdateStatus.unavailable:
          _availableUpdate = null;
          break;
        case AppUpdateStatus.autoInstallStarted:
        case AppUpdateStatus.installerPermissionRequired:
          break;
      }
    } finally {
      _isCheckingStartupUpdate = false;
    }
  }

  bool _shouldRunUpdateCheckNow() {
    final DateTime? lastCheckAt = _lastUpdateCheckAt;
    if (lastCheckAt == null) {
      return true;
    }
    return DateTime.now().difference(lastCheckAt) >= _updateCheckInterval;
  }

  String _updateAnnouncementKey(AppUpdateCheckResult result) {
    final String version = result.latestRelease?.version.trim() ?? '';
    if (version.isNotEmpty) {
      return version;
    }
    return 'auto:${result.currentVersion}';
  }

  String _updateVersionLabel(AppUpdateCheckResult result) {
    return result.latestRelease?.version.trim() ?? '';
  }

  Future<void> _announceAvailableUpdate(AppUpdateCheckResult result) async {
    _availableUpdate = result;
    final String updateKey = _updateAnnouncementKey(result);
    if (_notifiedUpdateKey != updateKey) {
      _notifiedUpdateKey = updateKey;
      await _appNotificationService.showUpdateAvailableNotification(
        versionLabel: _updateVersionLabel(result),
        canAutoInstall: result.canAutoInstall,
      );
    }

    if (_appLifecycleState != AppLifecycleState.resumed ||
        _shownUpdateDialogKey == updateKey) {
      return;
    }

    _shownUpdateDialogKey = updateKey;
    await _showStartupUpdateDialog(result);
  }

  Future<void> _attemptSelectedUpdate() async {
    if (_isCheckingStartupUpdate) {
      return;
    }

    _isCheckingStartupUpdate = true;
    try {
      final AppUpdateCheckResult result =
          await _appUpdateService.checkForStartupUpdate(startInstall: true);
      _retryStartupUpdateOnResume = result.shouldRetryOnResume;
      if (!mounted) {
        return;
      }

      switch (result.status) {
        case AppUpdateStatus.autoInstallStarted:
          _availableUpdate = null;
          _notifiedUpdateKey = null;
          await _appNotificationService.cancelUpdateNotification();
          if (result.message.isNotEmpty) {
            _showAuthMessage(result.message);
          }
          if (!kIsWeb && Platform.isAndroid && kDebugMode) {
            _showAuthMessage(
              'This Android install is a debug build. If the installer refuses the update, uninstall the dev build first and then install the GitHub release.',
            );
          }
          break;
        case AppUpdateStatus.installerPermissionRequired:
          if (result.message.isNotEmpty) {
            _showAuthMessage(result.message);
          }
          break;
        case AppUpdateStatus.manualUpdateAvailable:
          _availableUpdate = result;
          if (result.canAutoInstall) {
            await _announceAvailableUpdate(result);
          } else if (result.actionUrl != null) {
            await _openExternalUrl(result.actionUrl.toString());
          } else if (result.message.isNotEmpty) {
            _showAuthMessage(result.message);
          }
          break;
        case AppUpdateStatus.upToDate:
          _retryStartupUpdateOnResume = false;
          _availableUpdate = null;
          _notifiedUpdateKey = null;
          await _appNotificationService.cancelUpdateNotification();
          if (result.message.isNotEmpty) {
            _showAuthMessage(result.message);
          }
          break;
        case AppUpdateStatus.unavailable:
          _availableUpdate = null;
          if (result.message.isNotEmpty) {
            _showAuthMessage(result.message);
          }
          break;
      }
    } finally {
      _isCheckingStartupUpdate = false;
    }
  }

  Future<void> _showStartupUpdateDialog(AppUpdateCheckResult result) async {
    if (!mounted || _isShowingStartupUpdateDialog) {
      return;
    }

    final Uri? actionUrl = result.actionUrl;
    if (actionUrl == null && !result.canAutoInstall) {
      if (result.message.isNotEmpty) {
        _showAuthMessage(result.message);
      }
      return;
    }

    _isShowingStartupUpdateDialog = true;
    try {
      final bool? openUpdate = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          final String latestVersion = _updateVersionLabel(result);
          final String actionLabel =
              result.canAutoInstall ? 'Update now' : 'Download update';
          final String updateLead = latestVersion.isEmpty
              ? 'A Backchat update is available.'
              : 'Backchat $latestVersion is available.';
          final String content = result.canAutoInstall
              ? '$updateLead Install it now, or leave it for later.'
              : '$updateLead This platform still needs the latest download to finish the upgrade.';
          return AlertDialog(
            title: const Text('Update available'),
            content: Text(content),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(actionLabel),
              ),
            ],
          );
        },
      );
      if (openUpdate == true && mounted) {
        if (result.canAutoInstall) {
          await _attemptSelectedUpdate();
        } else if (actionUrl != null) {
          await _openExternalUrl(actionUrl.toString());
        }
      }
    } finally {
      _isShowingStartupUpdateDialog = false;
    }
  }

  void _startUpdatePolling() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer.periodic(_updateCheckInterval, (_) {
      unawaited(_checkForStartupUpdate());
    });
  }

  void _stopUpdatePolling() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = null;
  }

  void _startMessagePolling() {
    _messagePollTimer?.cancel();
    _messagePollTimer = Timer.periodic(_messagePollInterval, (_) {
      _syncMessages(showErrors: false);
    });
  }

  void _stopMessagePolling() {
    _messagePollTimer?.cancel();
    _messagePollTimer = null;
  }

  void _startContactRefresh() {
    _contactRefreshTimer?.cancel();
    _contactRefreshTimer = Timer.periodic(_contactRefreshInterval, (_) {
      _loadContacts();
    });
  }

  void _stopContactRefresh() {
    _contactRefreshTimer?.cancel();
    _contactRefreshTimer = null;
  }

  Future<void> _syncMessages({required bool showErrors}) async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null || _isSyncingMessages) {
      return;
    }

    _isSyncingMessages = true;
    try {
      final List<ChatMessage> newMessages =
          await _messagingService.syncIncoming(currentUser.id);
      if (newMessages.isNotEmpty) {
        await _loadContacts();
        await _notifyForIncomingMessages(newMessages);
        await _refreshConversation(scrollToBottom: true);
      }
      await _syncWindowUnreadCount();
    } on BackchatApiException catch (e) {
      if (showErrors) {
        _showAuthMessage(e.message);
      }
    } catch (_) {
      if (showErrors) {
        _showAuthMessage('Could not sync messages right now.');
      }
    } finally {
      _isSyncingMessages = false;
    }
  }

  Future<void> _selectContact(AppUser contact) async {
    setState(() => _selectedContact = contact);
    await _rememberSelectedConversation(contact);
    await _loadSelectedConversationBackground();
    await _refreshConversation(scrollToBottom: true);
    if (mounted && !_useCompactChatLayout(context)) {
      _messageFocusNode.requestFocus();
    }
  }

  Future<void> _rememberSelectedConversation(AppUser? contact) async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null) {
      return;
    }
    await _conversationSessionService.saveLastSelectedContactId(
      currentUserId: currentUser.id,
      contactUserId: contact?.id,
    );
  }

  Future<void> _restoreLastConversationSelection() async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null || _contacts.isEmpty) {
      return;
    }

    final String? lastSelectedContactId = await _conversationSessionService
        .loadLastSelectedContactId(currentUserId: currentUser.id);
    if (!mounted || _currentUser?.id != currentUser.id) {
      return;
    }
    if (lastSelectedContactId == null || lastSelectedContactId.isEmpty) {
      return;
    }

    final AppUser? restoredContact = _contacts.cast<AppUser?>().firstWhere(
          (AppUser? contact) => contact?.id == lastSelectedContactId,
          orElse: () => null,
        );
    if (restoredContact == null) {
      await _conversationSessionService.saveLastSelectedContactId(
        currentUserId: currentUser.id,
        contactUserId: null,
      );
      return;
    }

    setState(() {
      _selectedContact = restoredContact;
    });
    await _loadSelectedConversationBackground();
    await _refreshConversation(scrollToBottom: true);
  }

  Future<void> _loadSelectedConversationBackground() async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      if (mounted) {
        setState(() {
          _selectedConversationBackgroundUrl = null;
        });
      }
      return;
    }

    final String? backgroundUrl =
        await _conversationBackgroundService.loadBackgroundUrl(
      currentUserId: currentUser.id,
      contactUserId: selectedContact.id,
    );
    if (!mounted ||
        _currentUser?.id != currentUser.id ||
        _selectedContact?.id != selectedContact.id) {
      return;
    }

    setState(() {
      _selectedConversationBackgroundUrl = backgroundUrl;
    });
  }

  Future<void> _applyConversationBackground(String url) async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      return;
    }

    await _conversationBackgroundService.saveBackgroundUrl(
      currentUserId: currentUser.id,
      contactUserId: selectedContact.id,
      url: url,
    );
    if (!mounted ||
        _currentUser?.id != currentUser.id ||
        _selectedContact?.id != selectedContact.id) {
      return;
    }
    setState(() {
      _selectedConversationBackgroundUrl = url.trim().isEmpty ? null : url;
    });
    _showAuthMessage('Shared background applied.');
  }

  Future<void> _clearConversationBackground() async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      return;
    }

    await _conversationBackgroundService.clearBackgroundUrl(
      currentUserId: currentUser.id,
      contactUserId: selectedContact.id,
    );
    if (!mounted ||
        _currentUser?.id != currentUser.id ||
        _selectedContact?.id != selectedContact.id) {
      return;
    }
    setState(() {
      _selectedConversationBackgroundUrl = null;
    });
    _showAuthMessage('Conversation background cleared.');
  }

  Future<void> _refreshConversation({bool scrollToBottom = false}) async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      if (!mounted) {
        return;
      }
      setState(() => _conversation.clear());
      await _syncWindowUnreadCount();
      return;
    }

    final bool shouldMarkConversationRead =
        _appLifecycleState == AppLifecycleState.resumed;
    if (shouldMarkConversationRead) {
      await _messagingService.markConversationRead(
        currentUserId: currentUser.id,
        contactUserId: selectedContact.id,
      );
      await _appNotificationService.cancelNotification(
        _messageNotificationId(selectedContact.id),
      );
    }
    final List<ChatMessage> messages =
        await _messagingService.listForPair(currentUser.id, selectedContact.id);
    final List<_ConversationEntry> renderedConversation =
        <_ConversationEntry>[];

    for (final ChatMessage message in messages) {
      final ChatMessageContent content = await _decodeMessageContent(message);
      renderedConversation.add(
        _ConversationEntry(message: message, content: content),
      );
    }

    if (!mounted ||
        _currentUser?.id != currentUser.id ||
        _selectedContact?.id != selectedContact.id) {
      return;
    }

    setState(() {
      _conversation
        ..clear()
        ..addAll(renderedConversation);
    });

    if (scrollToBottom) {
      _ensureConversationBottomVisible(animated: false);
    }
    await _syncWindowUnreadCount();
  }

  Future<ChatMessageContent> _decodeMessageContent(ChatMessage message) async {
    final ChatMessageContent? directPayload =
        ChatMessageContent.tryFromTransportPayload(message.cipherText);
    if (directPayload != null) {
      return directPayload;
    }

    final ChatMessageContent? legacyPayload =
        ChatMessageContent.tryFromLegacyPayload(message.cipherText);
    if (legacyPayload != null) {
      return legacyPayload;
    }

    final String? plainText =
        _tryDecodePlainTextTransportPayload(message.cipherText);
    if (plainText != null) {
      return ChatMessageContent.text(plainText);
    }

    if (_messagingService.isRemoteTransportEnabled) {
      final String rawText = message.cipherText.trim();
      if (rawText.isNotEmpty) {
        return ChatMessageContent.text(rawText);
      }
      return ChatMessageContent.text('[Message unavailable]');
    }

    if (_sharedSecret == null) {
      return ChatMessageContent.text('[Message unavailable]');
    }

    try {
      final String decoded = await _encryptionService.decryptText(
        encodedPayload: message.cipherText,
        sharedSecret: _sharedSecret!,
        associatedData: _buildMessageAad(
          fromUserId: message.fromUserId,
          toUserId: message.toUserId,
        ),
      );
      final ChatMessageContent? structuredPayload =
          ChatMessageContent.tryFromTransportPayload(decoded);
      return structuredPayload ?? ChatMessageContent.text(decoded);
    } catch (_) {
      return ChatMessageContent.text('[Unable to read message]');
    }
  }

  String? _tryDecodePlainTextTransportPayload(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic> &&
          decoded['mode'] == _plainTextTransportMode) {
        return decoded['text']?.toString() ?? '';
      }
    } catch (_) {
      // Ignore and fall back to the local encryption demo decoder.
    }

    return null;
  }

  String _displayNameForUserId(String userId, {String? fallback}) {
    if (_currentUser?.id == userId) {
      return _currentUser!.displayName;
    }

    for (final AppUser contact in _contacts) {
      if (contact.id == userId) {
        return contact.displayName;
      }
    }

    return fallback ?? _usernameFromUserId(userId);
  }

  String _usernameFromUserId(String userId) {
    const String prefix = 'username:';
    if (userId.startsWith(prefix)) {
      return userId.substring(prefix.length);
    }
    return userId;
  }

  void _scrollConversationToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_conversationScrollController.hasClients) {
        return;
      }
      final double target =
          _conversationScrollController.position.maxScrollExtent;
      if (animated) {
        _conversationScrollController.animateTo(
          target + 80,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        _conversationScrollController.jumpTo(target);
      }
    });
  }

  void _revealLatestMessagesForReply() {
    _ensureConversationBottomVisible(requireComposerFocus: true);
  }

  void _ensureConversationBottomVisible({
    bool animated = true,
    bool requireComposerFocus = false,
  }) {
    if (_selectedContact == null || _conversation.isEmpty) {
      return;
    }
    _scrollConversationToBottom(animated: animated);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (!mounted || (requireComposerFocus && !_messageFocusNode.hasFocus)) {
          return;
        }
        _scrollConversationToBottom(animated: animated);
      }),
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 360), () {
        if (!mounted || (requireComposerFocus && !_messageFocusNode.hasFocus)) {
          return;
        }
        _scrollConversationToBottom(animated: animated);
      }),
    );
  }

  void _appendEmoji(String emoji) {
    final TextSelection selection = _messageController.selection;
    final String currentText = _messageController.text;
    final int start =
        selection.start >= 0 ? selection.start : currentText.length;
    final int end = selection.end >= 0 ? selection.end : currentText.length;
    final String nextText = currentText.replaceRange(start, end, emoji);
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _messageFocusNode.requestFocus();
  }

  Future<void> _syncWindowUnreadCount() async {
    final AppUser? currentUser = _currentUser;
    final int unreadCount = currentUser == null
        ? 0
        : _messagingService.totalUnreadCountForUser(currentUser.id);
    await _appWindowService.setUnreadCount(unreadCount);
  }

  Future<void> _notifyForIncomingMessages(List<ChatMessage> newMessages) async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null || newMessages.isEmpty) {
      return;
    }

    final Map<String, List<ChatMessage>> groupedBySender =
        <String, List<ChatMessage>>{};
    for (final ChatMessage message in newMessages) {
      if (!message.isIncomingFor(currentUser.id)) {
        continue;
      }
      groupedBySender
          .putIfAbsent(message.fromUserId, () => <ChatMessage>[])
          .add(message);
    }

    for (final MapEntry<String, List<ChatMessage>> entry
        in groupedBySender.entries) {
      if (!_shouldShowConversationNotification(entry.key)) {
        continue;
      }

      final ChatMessage latestMessage = entry.value.reduce(
        (ChatMessage current, ChatMessage next) =>
            next.sentAt.isAfter(current.sentAt) ? next : current,
      );
      final ChatMessageContent content =
          await _decodeMessageContent(latestMessage);
      final String preview = _notificationPreviewForContent(content);
      final int unreadCount = _messagingService.unreadCountForContact(
        currentUserId: currentUser.id,
        contactUserId: entry.key,
      );
      await _appNotificationService.showIncomingMessageNotification(
        notificationId: _messageNotificationId(entry.key),
        senderName: _displayNameForUserId(entry.key),
        body: preview.isEmpty ? 'New message' : preview,
        unreadCount: unreadCount,
      );
    }
  }

  String _notificationPreviewForContent(ChatMessageContent content) {
    final String preview = content.previewText.trim();
    if (preview.isEmpty) {
      return 'New message';
    }
    if (preview.length <= 120) {
      return preview;
    }
    return '${preview.substring(0, 117)}...';
  }

  Future<void> _syncCallNotification({
    required ActiveCallState previousState,
    required ActiveCallState nextState,
  }) async {
    if (nextState.isIncoming &&
        (!previousState.isIncoming ||
            previousState.callId != nextState.callId) &&
        nextState.peer != null &&
        _appLifecycleState != AppLifecycleState.resumed) {
      await _appNotificationService.showIncomingCallNotification(
        callerName: nextState.peer!.displayName,
        kind: nextState.kind,
      );
      return;
    }

    if (previousState.isIncoming && !nextState.isIncoming) {
      await _appNotificationService.cancelIncomingCallNotification();
    }
  }

  bool _shouldShowConversationNotification(String contactUserId) {
    return _appLifecycleState != AppLifecycleState.resumed ||
        _selectedContact?.id != contactUserId;
  }

  int _messageNotificationId(String contactUserId) {
    return _stableNotificationId('message:$contactUserId');
  }

  int _stableNotificationId(String value) {
    int hash = 17;
    for (final int codeUnit in value.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + codeUnit);
    }
    return hash & 0x3fffffff;
  }

  Future<void> _startCall(CallKind kind) async {
    final AppUser? selectedContact = _selectedContact;
    if (selectedContact == null) {
      return;
    }

    try {
      await _callService.startOutgoingCall(peer: selectedContact, kind: kind);
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage('Could not start the ${kind.name} call right now.');
    }
  }

  Future<void> _answerIncomingCall() async {
    try {
      await _callService.answerIncomingCall();
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage('Could not answer the call.');
    }
  }

  Future<void> _rejectIncomingCall() async {
    try {
      await _callService.rejectIncomingCall();
    } catch (_) {
      _showAuthMessage('Could not decline the call cleanly.');
    }
  }

  Future<void> _endCall() async {
    try {
      await _callService.endCall();
    } catch (_) {
      _showAuthMessage('Could not end the call cleanly.');
    }
  }

  List<Widget>? _buildAuthenticatedAppBarActions({
    required AppUser? user,
    required bool showingMobileConversation,
    required AppUser? selectedContact,
  }) {
    if (user == null) {
      return null;
    }

    final List<Widget> actions = <Widget>[];
    if (showingMobileConversation && selectedContact != null) {
      actions.addAll(_buildMobileConversationAppBarActions(selectedContact));
      if (_selectedConversationBackgroundUrl != null) {
        actions.add(
          IconButton(
            tooltip: 'Clear conversation background',
            onPressed: _clearConversationBackground,
            icon: const Icon(Icons.wallpaper_outlined),
          ),
        );
      }
    }

    actions.add(
      PopupMenuButton<_SessionMenuAction>(
        tooltip: 'Account options',
        enabled: !_isAuthBusy,
        onSelected: (_SessionMenuAction action) {
          switch (action) {
            case _SessionMenuAction.editProfile:
              _editProfile();
              return;
            case _SessionMenuAction.callSettings:
              _editCallSettings();
              return;
            case _SessionMenuAction.setStatusOnline:
              _changeStatus(PresenceStatus.online);
              return;
            case _SessionMenuAction.setStatusBusy:
              _changeStatus(PresenceStatus.busy);
              return;
            case _SessionMenuAction.setStatusOffline:
              _changeStatus(PresenceStatus.offline);
              return;
            case _SessionMenuAction.signOut:
              unawaited(_signOutCurrentUser());
              return;
          }
        },
        itemBuilder: (BuildContext context) =>
            const <PopupMenuEntry<_SessionMenuAction>>[
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.editProfile,
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('Edit profile'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.callSettings,
            child: ListTile(
              leading: Icon(Icons.settings_ethernet_outlined),
              title: Text('Call settings'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.setStatusOnline,
            child: ListTile(
              leading: Icon(Icons.circle, color: Colors.green, size: 16),
              title: Text('Set status: online'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.setStatusBusy,
            child: ListTile(
              leading: Icon(Icons.circle, color: Colors.orange, size: 16),
              title: Text('Set status: busy'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.setStatusOffline,
            child: ListTile(
              leading: Icon(Icons.circle, color: Colors.grey, size: 16),
              title: Text('Set status: offline'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem<_SessionMenuAction>(
            value: _SessionMenuAction.signOut,
            child: ListTile(
              leading: Icon(Icons.logout),
              title: Text('Sign out'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );

    return actions;
  }

  Future<void> _toggleCallMute() async {
    await _callService.toggleMute();
  }

  Future<void> _toggleCallVideo() async {
    await _callService.toggleVideoEnabled();
  }

  Future<void> _editCallSettings() async {
    CallSettings draft = _callService.settings;

    final CallSettings? nextSettings = await showDialog<CallSettings>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('Advanced call routing'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Use Auto for most people. Direct/VPN options prefer peer-to-peer routes over your own secure network when available.',
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<CallConnectionMode>(
                        initialValue: draft.connectionMode,
                        decoration: const InputDecoration(
                          labelText: 'Connection mode',
                          border: OutlineInputBorder(),
                        ),
                        items: CallConnectionMode.values
                            .map(
                              (CallConnectionMode mode) =>
                                  DropdownMenuItem<CallConnectionMode>(
                                value: mode,
                                child: Text(_callModeLabel(mode)),
                              ),
                            )
                            .toList(),
                        onChanged: (CallConnectionMode? value) {
                          if (value == null) {
                            return;
                          }
                          setDialogState(() {
                            draft = draft.copyWith(connectionMode: value);
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        value: draft.shareLocalCandidates,
                        onChanged: (bool value) {
                          setDialogState(() {
                            draft = draft.copyWith(shareLocalCandidates: value);
                          });
                        },
                        title: const Text('Share local/VPN addresses'),
                        subtitle: const Text(
                          'Use this for LAN or VPN peers that can route private addresses directly.',
                        ),
                      ),
                      SwitchListTile.adaptive(
                        value: draft.sharePublicCandidates,
                        onChanged: (bool value) {
                          setDialogState(() {
                            draft =
                                draft.copyWith(sharePublicCandidates: value);
                          });
                        },
                        title: const Text('Share public internet addresses'),
                        subtitle: const Text(
                          'Enable this when peers know their public routing is reachable and safe to expose.',
                        ),
                      ),
                      SwitchListTile.adaptive(
                        value: draft.allowRelayFallback,
                        onChanged: (bool value) {
                          setDialogState(() {
                            draft = draft.copyWith(allowRelayFallback: value);
                          });
                        },
                        title: const Text('Allow TURN relay fallback'),
                        subtitle: Text(
                          _callService.serverConfig.turnConfigured
                              ? 'Recommended outside trusted networks so calls can still connect.'
                              : 'TURN relay is not configured yet on the backend.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildCallDiagnosticsBlock(
                        diagnostics: _callService.state.diagnostics,
                        showTitle: true,
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(draft),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (nextSettings == null) {
      return;
    }

    await _callService.updateSettings(nextSettings);
    _showAuthMessage('Advanced call routing updated.');
  }

  Future<void> _continueWithUsername() async {
    if (_isAuthBusy) {
      return;
    }

    setState(() => _isAuthBusy = true);
    try {
      final UsernameSignInResult result =
          await _authService.signInOrCreateWithUsername(
        username: _usernameController.text,
        recoveryEmail: _usernameRecoveryEmailController.text,
        password: _passwordController.text,
      );

      switch (result.status) {
        case UsernameSignInStatus.signedIn:
          if (result.user != null) {
            await _activateUserSession(result.user!);
          }
          break;
        case UsernameSignInStatus.created:
          if (result.user != null) {
            await _activateUserSession(result.user!);
          }
          _showAuthMessage(
            'Username created and linked to your recovery email.',
          );
          break;
        case UsernameSignInStatus.passwordSet:
          if (result.user != null) {
            await _activateUserSession(result.user!);
          }
          _showAuthMessage(
            'Password saved for this username. Use it next time you sign in.',
          );
          break;
        case UsernameSignInStatus.invalidUsername:
          _showAuthMessage(
            'Choose 3-24 characters: letters, numbers, or underscore.',
          );
          break;
        case UsernameSignInStatus.usernameNeedsRecoveryEmail:
          _showAuthMessage(
            'That username is available. Add a recovery email to claim it.',
          );
          break;
        case UsernameSignInStatus.invalidRecoveryEmail:
          _showAuthMessage('Enter a valid recovery email address.');
          break;
        case UsernameSignInStatus.invalidPassword:
          _showAuthMessage('Use a password between 8 and 72 characters.');
          break;
        case UsernameSignInStatus.passwordRequired:
          _showAuthMessage(
              'This username is password-protected. Enter the password to continue.');
          break;
        case UsernameSignInStatus.passwordIncorrect:
          _showAuthMessage('That password is incorrect for this username.');
          break;
        case UsernameSignInStatus.passwordSetupNeedsRecoveryEmail:
          _showAuthMessage(
            'Add your recovery email to secure this older username with a password.',
          );
          break;
        case UsernameSignInStatus.recoveryEmailMismatch:
          _showAuthMessage(
            'That recovery email does not match this username, so the password was not changed.',
          );
          break;
        case UsernameSignInStatus.recoveryEmailAlreadyInUse:
          _showAuthMessage(
            'That email is already linked to ${result.linkedUsername}. Use recovery below.',
          );
          break;
        case UsernameSignInStatus.serverUnavailable:
          _showAuthMessage(
            'Could not reach the server, so sign-in was not completed.',
          );
          break;
      }
    } catch (_) {
      _showAuthMessage('Sign in failed unexpectedly. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isAuthBusy = false);
      }
    }
  }

  Future<void> _continueWithSocialProvider({
    required String providerLabel,
    required Future<AppUser?> Function() signIn,
  }) async {
    if (_isAuthBusy) {
      return;
    }

    setState(() => _isAuthBusy = true);
    try {
      final AppUser? user = await signIn();
      if (user == null) {
        _showAuthMessage(
          '$providerLabel sign-in completed, but no account was returned.',
        );
        return;
      }
      if (_currentUser?.id == user.id) {
        return;
      }
      await _activateUserSession(user);
    } on SocialOAuthLaunchException catch (e) {
      final String launchUrl = e.authorizationUri.toString();
      try {
        await Clipboard.setData(ClipboardData(text: launchUrl));
        _showAuthMessage(
          '$providerLabel sign-in link copied to clipboard. Open it in your browser, finish sign-in, then return to Backchat.',
        );
      } catch (_) {
        _showAuthMessage(
          '$providerLabel sign-in could not open a browser automatically. Open this link manually: $launchUrl',
        );
      }
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage(
        '$providerLabel sign-in failed unexpectedly. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _isAuthBusy = false);
      }
    }
  }

  Future<void> _recoverUsername() async {
    final String? username = await _authService
        .recoverUsernameForEmail(_recoveryEmailController.text);
    if (username == null) {
      _showAuthMessage('No username found for that email.');
      return;
    }

    _usernameController.text = username;
    _usernameRecoveryEmailController.text =
        _recoveryEmailController.text.trim();
    final String normalizedUsername = username.trim().toLowerCase();
    setState(() {
      _rememberedAccountSelection = _rememberedAccounts.any(
        (RememberedUsernameAccount account) =>
            account.normalizedUsername == normalizedUsername,
      )
          ? normalizedUsername
          : null;
    });
    _showAuthMessage('Recovered username: $username');
  }

  Future<bool> _inviteByUsername() async {
    if (_currentUser == null || _isInviteBusy) {
      return false;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isInviteBusy = true);
    try {
      final InviteByUsernameResult result =
          await _contactsService.inviteByUsername(
        currentUser: _currentUser!,
        username: _inviteUsernameController.text,
        authService: _authService,
      );

      switch (result.status) {
        case InviteByUsernameStatus.added:
          await _loadContacts();
          _inviteUsernameController.clear();
          _showAuthMessage('Added ${result.contact?.displayName} to contacts.');
          return true;
        case InviteByUsernameStatus.alreadyContact:
          _showAuthMessage(
            '${result.contact?.displayName} is already in your contacts.',
          );
          return false;
        case InviteByUsernameStatus.selfInvite:
          _showAuthMessage('You cannot add your own username as a contact.');
          return false;
        case InviteByUsernameStatus.notFound:
          _showAuthMessage('No account found with that username.');
          return false;
        case InviteByUsernameStatus.invalidUsername:
          _showAuthMessage(
            'Enter a valid username (3-24 letters/numbers/underscore).',
          );
          return false;
        case InviteByUsernameStatus.serverUnavailable:
          _showAuthMessage(
            'Invite service is currently unavailable. Please try again.',
          );
          return false;
      }
    } catch (_) {
      _showAuthMessage('Invite failed unexpectedly. Please try again.');
      return false;
    } finally {
      if (mounted) {
        setState(() => _isInviteBusy = false);
      }
    }
  }

  Future<void> _showCompactInviteSheet() async {
    if (_currentUser == null) {
      return;
    }

    bool isSubmitting = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            Future<void> submitInvite() async {
              if (isSubmitting) {
                return;
              }
              setSheetState(() {
                isSubmitting = true;
              });
              final bool added = await _inviteByUsername();
              if (!sheetContext.mounted) {
                return;
              }
              if (added) {
                Navigator.of(sheetContext).pop();
                return;
              }
              setSheetState(() {
                isSubmitting = false;
              });
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Invite contact',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close invite',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    'Add someone by username without covering the rest of the chat layout.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _inviteUsernameController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => submitInvite(),
                    decoration: const InputDecoration(
                      hintText: 'Invite by username',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: isSubmitting ? null : submitInvite,
                    icon: isSubmitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_add),
                    label: const Text('Add contact'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _editProfile() async {
    final AppUser? currentUser = _currentUser;
    if (currentUser == null) {
      return;
    }
    if (!_profileApi.isConfigured) {
      _showAuthMessage('Profile editing needs the shared backend enabled.');
      return;
    }

    final TextEditingController avatarController = TextEditingController(
      text: currentUser.avatarUrl,
    );
    final TextEditingController quoteController = TextEditingController(
      text: currentUser.quote,
    );

    AppUser? updatedUser;
    String? dialogError;
    bool isSaving = false;

    try {
      updatedUser = await showDialog<AppUser>(
        context: context,
        builder: (BuildContext context) {
          return StatefulBuilder(
            builder: (BuildContext context, StateSetter setDialogState) {
              Future<void> submit() async {
                setDialogState(() {
                  isSaving = true;
                  dialogError = null;
                });
                try {
                  final AppUser profile = await _profileApi.updateProfile(
                    avatarUrl: avatarController.text.trim(),
                    quote: quoteController.text.trim(),
                  );
                  if (!context.mounted) {
                    return;
                  }
                  Navigator.of(context).pop(profile);
                } on BackchatApiException catch (e) {
                  setDialogState(() {
                    dialogError = e.message;
                    isSaving = false;
                  });
                } catch (_) {
                  setDialogState(() {
                    dialogError = 'Could not update your profile right now.';
                    isSaving = false;
                  });
                }
              }

              return AlertDialog(
                title: const Text('Edit profile'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextField(
                        controller: avatarController,
                        decoration: const InputDecoration(
                          labelText: 'Avatar URL',
                          hintText: 'https://example.com/avatar.png',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: quoteController,
                        maxLength: 160,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Quote',
                          hintText: 'A short line your contacts will see',
                        ),
                      ),
                      if (dialogError != null) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          dialogError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed:
                        isSaving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: isSaving ? null : submit,
                    child: Text(isSaving ? 'Saving...' : 'Save'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      avatarController.dispose();
      quoteController.dispose();
    }

    if (!mounted || updatedUser == null) {
      return;
    }

    setState(() {
      _currentUser = updatedUser;
    });
    await _authService.rememberAuthenticatedUser(updatedUser);
    await _loadContacts();
    _showAuthMessage('Profile updated.');
  }

  void _changeStatus(PresenceStatus status) {
    if (_currentUser == null) {
      return;
    }
    setState(() {
      _currentUser = _currentUser!.copyWith(status: status);
    });
  }

  List<int> _buildMessageAad({
    required String fromUserId,
    required String toUserId,
  }) {
    return utf8.encode('$fromUserId|$toUserId');
  }

  Future<void> _sendTextMessage() async {
    final String clearText = _messageController.text.trim();
    if (clearText.isEmpty) {
      return;
    }

    await _sendContentMessage(ChatMessageContent.text(clearText));
    _messageController.clear();
  }

  Future<ChatMessageContent> _prepareContentForSend(
    ChatMessageContent content,
  ) async {
    if (!_messagingService.isRemoteTransportEnabled ||
        (content.kind != ChatMessageContentKind.image &&
            content.kind != ChatMessageContentKind.gif) ||
        !content.hasUrl ||
        !_keyboardMediaService.isDataUrl(content.url)) {
      return content;
    }

    final Uint8List? bytes =
        _keyboardMediaService.tryDecodeDataUrl(content.url);
    final String? mimeType =
        _keyboardMediaService.tryExtractDataUrlMimeType(content.url);
    if (bytes == null ||
        bytes.isEmpty ||
        mimeType == null ||
        mimeType.isEmpty) {
      throw const BackchatApiException(
        status: 'invalid_media',
        message: 'That GIF or image could not be prepared for sending.',
      );
    }

    final UploadedMedia uploadedMedia = await _profileApi.uploadMedia(
      bytes: bytes,
      mimeType: mimeType,
      filename: _uploadFilenameForContent(
        content: content,
        mimeType: mimeType,
      ),
    );

    return switch (content.kind) {
      ChatMessageContentKind.gif => ChatMessageContent.gif(
          url: uploadedMedia.url,
          caption: content.text,
        ),
      ChatMessageContentKind.image => ChatMessageContent.image(
          url: uploadedMedia.url,
          caption: content.text,
        ),
      _ => content,
    };
  }

  String _uploadFilenameForContent({
    required ChatMessageContent content,
    required String mimeType,
  }) {
    final String extension = switch (mimeType.trim().toLowerCase()) {
      'image/gif' => 'gif',
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final String prefix = content.kind == ChatMessageContentKind.gif
        ? 'backchat-gif'
        : 'backchat-image';
    return '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}.$extension';
  }

  Future<void> _sendContentMessage(ChatMessageContent content) async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      return;
    }

    final ChatMessageContent preparedContent;
    try {
      preparedContent = await _prepareContentForSend(content);
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
      return;
    } catch (_) {
      _showAuthMessage('Could not prepare that GIF or image right now.');
      return;
    }

    final String payload = preparedContent.toTransportPayload();
    final int payloadSize = utf8.encode(payload).length;
    if (_messagingService.isRemoteTransportEnabled &&
        payloadSize > (MediaAttachmentService.maxInlineBytes * 2)) {
      _showAuthMessage(
        'That image or GIF is too large to send directly. Pick a smaller file or share a link instead.',
      );
      return;
    }
    if (!_messagingService.isRemoteTransportEnabled &&
        payloadSize > (MediaAttachmentService.maxInlineBytes * 2)) {
      _showAuthMessage(
        'That image or GIF is too large to send in offline mode. Sign in to the Backchat server or choose a smaller file.',
      );
      return;
    }

    late final String cipherText;
    if (_messagingService.isRemoteTransportEnabled) {
      cipherText = payload;
    } else {
      if (_sharedSecret == null) {
        return;
      }
      final List<int> aad = _buildMessageAad(
        fromUserId: currentUser.id,
        toUserId: selectedContact.id,
      );
      cipherText = await _encryptionService.encryptText(
        plainText: payload,
        sharedSecret: _sharedSecret!,
        associatedData: aad,
      );
    }

    final DateTime sentAt = DateTime.now();
    final ChatMessage message = ChatMessage(
      localId: [
        'local',
        currentUser.id,
        selectedContact.id,
        sentAt.toUtc().microsecondsSinceEpoch.toString(),
      ].join(':'),
      fromUserId: currentUser.id,
      toUserId: selectedContact.id,
      cipherText: cipherText,
      sentAt: sentAt,
      isRead: true,
    );

    try {
      await _messagingService.send(message);
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
      return;
    } catch (_) {
      _showAuthMessage('Could not send message right now.');
      return;
    }

    await _refreshConversation(scrollToBottom: true);
    await _syncMessages(showErrors: false);
  }

  Future<void> _sendStickerMessage(_StickerPreset sticker) async {
    await _sendContentMessage(
      ChatMessageContent.sticker(
        emoji: sticker.emoji,
        label: sticker.label,
      ),
    );
  }

  Future<void> _showStickerPicker() async {
    final _StickerPreset? selected = await showDialog<_StickerPreset>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Send sticker'),
          content: SizedBox(
            width: 340,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _stickerPresets
                  .map(
                    (_StickerPreset sticker) => InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.of(context).pop(sticker),
                      child: Container(
                        width: 92,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              sticker.emoji,
                              style: const TextStyle(fontSize: 32),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              sticker.label,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (selected == null) {
      return;
    }
    await _sendStickerMessage(selected);
  }

  Future<void> _sendKeyboardInsertedContent(
    KeyboardInsertedContent insertedContent,
  ) async {
    final AppUser? selectedContact = _selectedContact;
    if (selectedContact == null) {
      _showAuthMessage('Select a contact before sending keyboard media.');
      return;
    }

    try {
      final ChatMessageContent content = await _keyboardMediaService
          .contentFromInsertedContent(insertedContent);
      await _sendContentMessage(content);
    } on KeyboardMediaException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage('Could not send that GIF or image from the keyboard.');
    }
  }

  Future<void> _pickAndSendSelectedMedia({
    required bool gifsOnly,
  }) async {
    try {
      final ChatMessageContent? content =
          await _pickSelectedMediaContent(gifsOnly: gifsOnly);
      if (content == null) {
        return;
      }
      await _sendContentMessage(content);
    } on MediaAttachmentException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage('Could not open that media file right now.');
    }
  }

  Future<ChatMessageContent?> _pickSelectedMediaContent({
    required bool gifsOnly,
  }) async {
    final ChatMessageContent? content =
        await _mediaAttachmentService.pickVisualMedia();
    if (content == null) {
      return null;
    }
    if (gifsOnly && content.kind != ChatMessageContentKind.gif) {
      throw const MediaAttachmentException('Choose a GIF file to send a GIF.');
    }
    if (!gifsOnly && content.kind == ChatMessageContentKind.gif) {
      throw const MediaAttachmentException(
        'Choose a photo or image file here, or use GIF to send animations.',
      );
    }
    return content;
  }

  Future<void> _showGifPicker() async {
    if (!_giphyService.isConfigured) {
      await _pickAndSendSelectedMedia(gifsOnly: true);
      return;
    }

    final GiphyPickerResult? result = await showDialog<GiphyPickerResult>(
      context: context,
      builder: (BuildContext dialogContext) {
        return GiphyPickerDialog(
          giphyService: _giphyService,
          languageCode: Localizations.localeOf(dialogContext).languageCode,
        );
      },
    );
    if (result == null) {
      return;
    }

    switch (result) {
      case GiphyPickedGifResult():
        await _sendContentMessage(result.content);
      case GiphyPickDeviceGifResult():
        await _pickAndSendSelectedMedia(gifsOnly: true);
    }
  }

  Future<void> _sendDroppedVisualMedia(List<XFile> files) async {
    if (files.isEmpty) {
      return;
    }
    try {
      final ChatMessageContent content =
          await _mediaAttachmentService.contentFromFile(files.first);
      await _sendContentMessage(content);
    } on MediaAttachmentException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage('Could not send that dropped image or GIF.');
    }
  }

  ContentInsertionConfiguration? _composerContentInsertionConfiguration(
    AppUser? selectedContact,
  ) {
    if (!Platform.isAndroid || selectedContact == null) {
      return null;
    }
    return ContentInsertionConfiguration(
      allowedMimeTypes: KeyboardMediaService.supportedMimeTypes,
      onContentInserted: (KeyboardInsertedContent insertedContent) {
        unawaited(_sendKeyboardInsertedContent(insertedContent));
      },
    );
  }

  Future<void> _composeMediaMessage({
    required ChatMessageContentKind kind,
    required String title,
    required String urlHint,
    required String captionLabel,
  }) async {
    final TextEditingController urlController = TextEditingController();
    final TextEditingController captionController = TextEditingController();
    String? validationError;

    try {
      final ChatMessageContent? result = await showDialog<ChatMessageContent>(
        context: context,
        builder: (BuildContext dialogContext) {
          return StatefulBuilder(
            builder: (BuildContext context, StateSetter setDialogState) {
              void submit() {
                final String rawUrl = urlController.text.trim();
                final Uri? uri = Uri.tryParse(rawUrl);
                final bool validUrl = uri != null &&
                    uri.hasScheme &&
                    (uri.scheme == 'https' || uri.scheme == 'http');
                if (!validUrl) {
                  setDialogState(() {
                    validationError = 'Enter a valid http or https URL.';
                  });
                  return;
                }

                final String caption = captionController.text.trim();
                final ChatMessageContent content = switch (kind) {
                  ChatMessageContentKind.image => ChatMessageContent.image(
                      url: rawUrl,
                      caption: caption,
                    ),
                  ChatMessageContentKind.gif => ChatMessageContent.gif(
                      url: rawUrl,
                      caption: caption,
                    ),
                  ChatMessageContentKind.background =>
                    ChatMessageContent.background(
                      url: rawUrl,
                      label: caption,
                    ),
                  ChatMessageContentKind.video => ChatMessageContent.video(
                      url: rawUrl,
                      caption: caption,
                    ),
                  ChatMessageContentKind.audio => ChatMessageContent.audio(
                      url: rawUrl,
                      caption: caption,
                    ),
                  ChatMessageContentKind.file => ChatMessageContent.file(
                      url: rawUrl,
                      label: caption,
                    ),
                  _ => ChatMessageContent.text(caption),
                };
                Navigator.of(dialogContext).pop(content);
              }

              return AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextField(
                        controller: urlController,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Media URL',
                          hintText: urlHint,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: captionController,
                        decoration: InputDecoration(
                          labelText: captionLabel,
                          hintText: 'Optional',
                        ),
                      ),
                      if (validationError != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          validationError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: submit,
                    child: const Text('Send'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (result == null) {
        return;
      }
      await _sendContentMessage(result);
    } finally {
      urlController.dispose();
      captionController.dispose();
    }
  }

  Future<void> _handleAttachmentAction(
    _ComposerAttachmentAction action,
  ) async {
    switch (action) {
      case _ComposerAttachmentAction.sticker:
        await _showStickerPicker();
        return;
      case _ComposerAttachmentAction.gif:
        await _showGifPicker();
        return;
      case _ComposerAttachmentAction.image:
        await _pickAndSendSelectedMedia(gifsOnly: false);
        return;
      case _ComposerAttachmentAction.background:
        await _composeMediaMessage(
          kind: ChatMessageContentKind.background,
          title: 'Share background',
          urlHint: 'https://example.com/wallpaper.jpg',
          captionLabel: 'Background name',
        );
        return;
      case _ComposerAttachmentAction.video:
        await _composeMediaMessage(
          kind: ChatMessageContentKind.video,
          title: 'Send video',
          urlHint: 'https://example.com/video.mp4',
          captionLabel: 'Caption',
        );
        return;
      case _ComposerAttachmentAction.audio:
        await _composeMediaMessage(
          kind: ChatMessageContentKind.audio,
          title: 'Send audio',
          urlHint: 'https://example.com/audio.mp3',
          captionLabel: 'Caption',
        );
        return;
      case _ComposerAttachmentAction.file:
        await _composeMediaMessage(
          kind: ChatMessageContentKind.file,
          title: 'Send file link',
          urlHint: 'https://example.com/document.pdf',
          captionLabel: 'File label',
        );
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? user = _currentUser;
    final bool compactLayout = user != null && _useCompactChatLayout(context);
    final bool showingMobileConversation =
        compactLayout && _selectedContact != null;

    return PopScope<void>(
      canPop: !showingMobileConversation,
      onPopInvokedWithResult: (bool didPop, void _) {
        if (!didPop && showingMobileConversation) {
          _closeMobileConversation();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: showingMobileConversation
              ? IconButton(
                  onPressed: _closeMobileConversation,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: showingMobileConversation
              ? _buildMobileConversationAppBarTitle(_selectedContact!)
              : const Text('Backchat Messenger'),
          actions: _buildAuthenticatedAppBarActions(
            user: user,
            showingMobileConversation: showingMobileConversation,
            selectedContact: _selectedContact,
          ),
        ),
        body: user == null
            ? _buildAuthView()
            : _buildChatView(
                user,
                compactLayout: compactLayout,
              ),
      ),
    );
  }

  Widget _buildAuthView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Sign in',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with a username, recovery email, and optional password. Saved sign-ins stay on this device so you can pick them again later.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_rememberedAccounts.isNotEmpty) ...<Widget>[
                  DropdownButtonFormField<String>(
                    initialValue: _rememberedAccountSelection,
                    decoration: const InputDecoration(
                      labelText: 'Autofill a remembered sign-in',
                      border: OutlineInputBorder(),
                    ),
                    items: _rememberedAccounts
                        .map(
                          (RememberedUsernameAccount account) =>
                              DropdownMenuItem<String>(
                            value: account.normalizedUsername,
                            child: Text(
                              '${account.username}  |  ${account.recoveryEmail}${account.hasPassword ? '  |  secured' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (String? normalizedUsername) {
                      if (normalizedUsername == null) {
                        return;
                      }
                      for (final RememberedUsernameAccount account
                          in _rememberedAccounts) {
                        if (account.normalizedUsername == normalizedUsername) {
                          _applyRememberedAccount(account);
                          break;
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _rememberedAccounts.length == 1
                        ? '1 saved sign-in on this device.'
                        : '${_rememberedAccounts.length} saved sign-ins on this device.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Username sign-in',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'e.g. crypto_owl',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _usernameRecoveryEmailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText:
                        'Recovery email (required for new usernames and password setup)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText:
                        'Password (optional at first, required once you set one)',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Legacy usernames can still sign in without a password until you add one. New passwords must be 8-72 characters.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  'Use recovery email only if you forgot your username.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _isAuthBusy ? null : _continueWithUsername,
                  icon: _isAuthBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_isAuthBusy ? 'Working...' : 'Continue'),
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Or continue with',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Backchat opens your browser to finish sign-in securely.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _isAuthBusy
                          ? null
                          : () => _continueWithSocialProvider(
                                providerLabel: 'Google',
                                signIn: _authService.signInWithGoogle,
                              ),
                      icon: const Icon(Icons.g_mobiledata),
                      label: const Text('Google'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isAuthBusy
                          ? null
                          : () => _continueWithSocialProvider(
                                providerLabel: 'Facebook',
                                signIn: _authService.signInWithFacebook,
                              ),
                      icon: const Icon(Icons.facebook),
                      label: const Text('Facebook'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isAuthBusy
                          ? null
                          : () => _continueWithSocialProvider(
                                providerLabel: 'X',
                                signIn: _authService.signInWithX,
                              ),
                      icon: const Icon(Icons.alternate_email),
                      label: const Text('X'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Recover username by email',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _recoveryEmailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Recovery email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _recoverUsername,
                  icon: const Icon(Icons.mail),
                  label: const Text('Recover username'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChatView(
    AppUser user, {
    required bool compactLayout,
  }) {
    if (compactLayout) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: _selectedContact == null
            ? _buildCompactContactsView(user)
            : _buildCompactConversationView(user, _selectedContact!),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wideLayout = constraints.maxWidth >= 980;
          final Widget conversationPane = Expanded(
            flex: wideLayout ? 7 : 1,
            child: _buildConversationPane(),
          );
          final Widget contactsPane = SizedBox(
            width: wideLayout ? 320 : double.infinity,
            height: wideLayout ? double.infinity : 340,
            child: _buildContactsPane(user),
          );

          if (wideLayout) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                conversationPane,
                const SizedBox(width: 16),
                contactsPane,
              ],
            );
          }

          return Column(
            children: <Widget>[
              conversationPane,
              const SizedBox(height: 16),
              contactsPane,
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobileConversationAppBarTitle(AppUser contact) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          contact.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          _contactStatusLabel(contact),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  List<Widget> _buildMobileConversationAppBarActions(AppUser contact) {
    final bool anotherCallIsActive = _callService.state.isInProgress &&
        _callService.state.peer?.id != contact.id;
    return <Widget>[
      IconButton(
        tooltip: 'Voice call',
        onPressed:
            anotherCallIsActive ? null : () => _startCall(CallKind.audio),
        icon: const Icon(Icons.call_outlined),
      ),
      IconButton(
        tooltip: 'Video call',
        onPressed:
            anotherCallIsActive ? null : () => _startCall(CallKind.video),
        icon: const Icon(Icons.videocam_outlined),
      ),
    ];
  }

  Widget _buildCompactContactsView(AppUser user) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        _buildCompactUserCard(user),
        if (!_callService.state.isIdle) ...<Widget>[
          const SizedBox(height: 12),
          _buildCallPanel(compactLayout: true),
        ],
        const SizedBox(height: 12),
        _buildCompactContactsPane(user),
      ],
    );
  }

  Widget _buildCompactConversationView(AppUser user, AppUser selectedContact) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!_callService.state.isIdle) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: _buildCallPanel(compactLayout: true),
            ),
          ] else
            const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: _buildConversationBody(
              user: user,
              selectedContact: selectedContact,
            ),
          ),
          _buildMessageComposer(
            selectedContact: selectedContact,
            compactLayout: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactUserCard(AppUser user) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  backgroundImage: user.avatarUrl.isNotEmpty
                      ? NetworkImage(user.avatarUrl)
                      : null,
                  child:
                      user.avatarUrl.isEmpty ? const Icon(Icons.person) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        user.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        user.username.isNotEmpty
                            ? '@${user.username}'
                            : 'Signed in',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (user.quote.isNotEmpty)
                        Text(
                          user.quote,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _editCallSettings,
                  icon: const Icon(Icons.settings_ethernet_outlined),
                  label: const Text('Call settings'),
                ),
                OutlinedButton.icon(
                  onPressed: _editProfile,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit profile'),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<PresenceStatus>(
                        value: user.status,
                        items: PresenceStatus.values
                            .map(
                              (PresenceStatus status) =>
                                  DropdownMenuItem<PresenceStatus>(
                                value: status,
                                child: Text(status.name),
                              ),
                            )
                            .toList(),
                        onChanged: (PresenceStatus? value) {
                          if (value != null) {
                            _changeStatus(value);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _isAuthBusy ? null : _signOutCurrentUser,
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationBody({
    required AppUser user,
    required AppUser? selectedContact,
  }) {
    final Widget content;
    if (selectedContact == null) {
      content = _buildEmptyConversationState(
        title: 'Open a conversation',
        subtitle:
            'Select a contact from the contact list to load previous messages and start chatting.',
      );
      return content;
    }

    if (_conversation.isEmpty) {
      content = _buildEmptyConversationState(
        title: 'No messages yet',
        subtitle:
            'Your conversation history is stored locally on this device once you start chatting.',
      );
      return _buildConversationCanvas(content);
    }

    content = ListView.builder(
      controller: _conversationScrollController,
      padding: const EdgeInsets.all(18),
      itemCount: _conversation.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildMessageBubble(
          entry: _conversation[index],
          currentUser: user,
        );
      },
    );
    return _buildConversationCanvas(content);
  }

  Widget _buildMessageComposer({
    required AppUser? selectedContact,
    required bool compactLayout,
  }) {
    final Widget emojiButton = PopupMenuButton<String>(
      tooltip: 'Insert emoji',
      onSelected: _appendEmoji,
      itemBuilder: (BuildContext context) {
        const List<String> emojis = <String>[
          '😀',
          '😂',
          '😍',
          '👍',
          '🎉',
          '❤️',
          '👀',
        ];
        return emojis
            .map(
              (String emoji) => PopupMenuItem<String>(
                value: emoji,
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            )
            .toList();
      },
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.emoji_emotions_outlined),
      ),
    );

    final Widget attachmentButton = PopupMenuButton<_ComposerAttachmentAction>(
      tooltip: 'Send media',
      enabled: selectedContact != null,
      onSelected: _handleAttachmentAction,
      itemBuilder: (BuildContext context) =>
          const <PopupMenuEntry<_ComposerAttachmentAction>>[
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.sticker,
          child: ListTile(
            leading: Icon(Icons.emoji_emotions),
            title: Text('Sticker'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.gif,
          child: ListTile(
            leading: Icon(Icons.gif_box_outlined),
            title: Text('GIF'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.image,
          child: ListTile(
            leading: Icon(Icons.image_outlined),
            title: Text('Image'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.background,
          child: ListTile(
            leading: Icon(Icons.wallpaper_outlined),
            title: Text('Background'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.video,
          child: ListTile(
            leading: Icon(Icons.videocam_outlined),
            title: Text('Video'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.audio,
          child: ListTile(
            leading: Icon(Icons.audiotrack_outlined),
            title: Text('Audio'),
          ),
        ),
        PopupMenuItem<_ComposerAttachmentAction>(
          value: _ComposerAttachmentAction.file,
          child: ListTile(
            leading: Icon(Icons.attach_file),
            title: Text('File link'),
          ),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.add_circle_outline),
      ),
    );

    final Widget composerField = TextField(
      controller: _messageController,
      focusNode: _messageFocusNode,
      contentInsertionConfiguration:
          _composerContentInsertionConfiguration(selectedContact),
      onSubmitted: (_) => _sendTextMessage(),
      minLines: 1,
      maxLines: compactLayout ? 6 : 4,
      decoration: InputDecoration(
        hintText: selectedContact == null
            ? 'Select a contact to start chatting'
            : 'Type a message for ${selectedContact.displayName}',
        border: const OutlineInputBorder(),
      ),
    );

    final Widget sendButton = FilledButton.icon(
      onPressed: selectedContact == null ? null : _sendTextMessage,
      icon: const Icon(Icons.send),
      label: const Text('Send'),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: compactLayout
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                composerField,
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    attachmentButton,
                    const SizedBox(width: 8),
                    emojiButton,
                    const SizedBox(width: 8),
                    sendButton,
                  ],
                ),
              ],
            )
          : Row(
              children: <Widget>[
                Expanded(child: composerField),
                const SizedBox(width: 10),
                attachmentButton,
                const SizedBox(width: 2),
                emojiButton,
                const SizedBox(width: 2),
                sendButton,
              ],
            ),
    );
  }

  Widget _buildDesktopConversationHeader(AppUser? selectedContact) {
    final ThemeData theme = Theme.of(context);
    if (selectedContact == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Text(
          'Select a contact to start chatting.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    final bool anotherCallIsActive = _callService.state.isInProgress &&
        _callService.state.peer?.id != selectedContact.id;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 22,
            backgroundImage: selectedContact.avatarUrl.isNotEmpty
                ? NetworkImage(selectedContact.avatarUrl)
                : null,
            child: selectedContact.avatarUrl.isEmpty
                ? Text(
                    selectedContact.displayName.characters.first.toUpperCase(),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  selectedContact.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  _contactStatusLabel(selectedContact),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (_selectedConversationBackgroundUrl != null)
            IconButton(
              tooltip: 'Clear conversation background',
              onPressed: _clearConversationBackground,
              icon: const Icon(Icons.wallpaper_outlined),
            ),
          IconButton(
            tooltip: 'Voice call',
            onPressed:
                anotherCallIsActive ? null : () => _startCall(CallKind.audio),
            icon: const Icon(Icons.call_outlined),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed:
                anotherCallIsActive ? null : () => _startCall(CallKind.video),
            icon: const Icon(Icons.videocam_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationPane() {
    final AppUser user = _currentUser!;
    final AppUser? selectedContact = _selectedContact;
    final ThemeData theme = Theme.of(context);
    final Widget conversationPane = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isDraggingVisualMedia
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: _isDraggingVisualMedia ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildDesktopConversationHeader(selectedContact),
          if (!_callService.state.isIdle) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _buildCallPanel(),
            ),
          ],
          const Divider(height: 1),
          Expanded(
            child: _buildConversationBody(
              user: user,
              selectedContact: selectedContact,
            ),
          ),
          _buildMessageComposer(
            selectedContact: selectedContact,
            compactLayout: false,
          ),
        ],
      ),
    );

    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return conversationPane;
    }

    return DropTarget(
      onDragEntered: (_) {
        if (_selectedContact == null) {
          return;
        }
        setState(() {
          _isDraggingVisualMedia = true;
        });
      },
      onDragExited: (_) {
        if (_isDraggingVisualMedia) {
          setState(() {
            _isDraggingVisualMedia = false;
          });
        }
      },
      onDragDone: (DropDoneDetails details) {
        if (_isDraggingVisualMedia) {
          setState(() {
            _isDraggingVisualMedia = false;
          });
        }
        if (_selectedContact == null) {
          _showAuthMessage('Select a contact before dropping an image or GIF.');
          return;
        }
        unawaited(_sendDroppedVisualMedia(details.files));
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          conversationPane,
          if (_isDraggingVisualMedia)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: theme.colorScheme.primary),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      child: Text(
                        'Drop an image or GIF to send it',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConversationCanvas(Widget child) {
    final String? backgroundUrl = _selectedConversationBackgroundUrl;
    if (backgroundUrl == null || backgroundUrl.trim().isEmpty) {
      return child;
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: Image.network(
            backgroundUrl,
            fit: BoxFit.cover,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) {
              return const SizedBox.shrink();
            },
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withValues(
                    alpha: 0.78,
                  ),
            ),
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildCallPanel({bool compactLayout = false}) {
    final ThemeData theme = Theme.of(context);
    final ActiveCallState callState = _callService.state;
    final AppUser? peer = callState.peer;
    if (peer == null) {
      return const SizedBox.shrink();
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  callState.kind == CallKind.video
                      ? Icons.videocam
                      : Icons.graphic_eq,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${callState.kind.name.toUpperCase()} call with ${peer.displayName}',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        callState.statusText,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildCallMediaStage(callState, compactLayout: compactLayout),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _buildCallActionButtons(callState),
            ),
            if (!compactLayout) ...<Widget>[
              const SizedBox(height: 12),
              _buildCallDiagnosticsBlock(
                diagnostics: callState.diagnostics,
                showTitle: false,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCallMediaStage(
    ActiveCallState callState, {
    bool compactLayout = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final AppUser? peer = callState.peer;
    if (peer == null) {
      return const SizedBox.shrink();
    }

    final bool showRemoteVideo =
        callState.kind == CallKind.video && callState.hasRemoteVideo;
    return SizedBox(
      height: compactLayout ? 160 : 220,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.inverseSurface,
                ),
                child: showRemoteVideo
                    ? RTCVideoView(
                        _callService.remoteRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircleAvatar(
                              radius: 28,
                              backgroundImage: peer.avatarUrl.isNotEmpty
                                  ? NetworkImage(peer.avatarUrl)
                                  : null,
                              child: peer.avatarUrl.isEmpty
                                  ? Text(
                                      peer.displayName.characters.first
                                          .toUpperCase(),
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              callState.statusText,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onInverseSurface,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
          if (callState.kind == CallKind.video &&
              callState.isVideoEnabled &&
              _callService.localRenderer.srcObject != null)
            Positioned(
              right: 12,
              bottom: 12,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 96,
                  height: 132,
                  child: RTCVideoView(
                    _callService.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildCallActionButtons(ActiveCallState callState) {
    if (callState.isIncoming) {
      return <Widget>[
        FilledButton.icon(
          onPressed: _answerIncomingCall,
          icon: Icon(
            callState.kind == CallKind.video ? Icons.videocam : Icons.call,
          ),
          label: Text(
            callState.kind == CallKind.video ? 'Answer video' : 'Answer call',
          ),
        ),
        OutlinedButton.icon(
          onPressed: _rejectIncomingCall,
          icon: const Icon(Icons.call_end),
          label: const Text('Decline'),
        ),
      ];
    }

    if (callState.isOutgoing) {
      return <Widget>[
        OutlinedButton.icon(
          onPressed: _endCall,
          icon: const Icon(Icons.call_end),
          label: const Text('Cancel'),
        ),
      ];
    }

    if (callState.lifecycle == CallLifecycle.connecting ||
        callState.lifecycle == CallLifecycle.active) {
      return <Widget>[
        FilledButton.tonalIcon(
          onPressed: _toggleCallMute,
          icon: Icon(callState.isMuted ? Icons.mic_off : Icons.mic),
          label: Text(callState.isMuted ? 'Unmute' : 'Mute'),
        ),
        if (callState.kind == CallKind.video)
          FilledButton.tonalIcon(
            onPressed: _toggleCallVideo,
            icon: Icon(
              callState.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
            ),
            label: Text(
              callState.isVideoEnabled ? 'Camera on' : 'Camera off',
            ),
          ),
        OutlinedButton.icon(
          onPressed: _endCall,
          icon: const Icon(Icons.call_end),
          label: const Text('Hang up'),
        ),
      ];
    }

    return <Widget>[
      OutlinedButton(
        onPressed: () => _callService.clearEndedState(),
        child: const Text('Dismiss'),
      ),
    ];
  }

  Widget _buildCallDiagnosticsBlock({
    required CallDiagnostics diagnostics,
    required bool showTitle,
  }) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (showTitle) ...<Widget>[
              Text(
                'Diagnostics',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
            ],
            _buildDiagnosticsLine(
              'Mode',
              _callModeLabel(_callService.settings.connectionMode),
            ),
            _buildDiagnosticsLine('Route', diagnostics.routeSummary),
            _buildDiagnosticsLine(
              'Connection',
              diagnostics.connectionState,
            ),
            _buildDiagnosticsLine(
              'Local/VPN IPs',
              diagnostics.localHostAddresses.isEmpty
                  ? 'none discovered'
                  : diagnostics.localHostAddresses.join(', '),
            ),
            _buildDiagnosticsLine(
              'Public IPs',
              diagnostics.publicAddresses.isEmpty
                  ? 'none discovered'
                  : diagnostics.publicAddresses.join(', '),
            ),
            _buildDiagnosticsLine(
              'Relay IPs',
              diagnostics.relayAddresses.isEmpty
                  ? diagnostics.turnConfigured
                      ? 'none in use'
                      : 'TURN not configured'
                  : diagnostics.relayAddresses.join(', '),
            ),
            _buildDiagnosticsLine(
              'Remote candidate types',
              diagnostics.remoteCandidateTypes.isEmpty
                  ? 'none yet'
                  : diagnostics.remoteCandidateTypes.join(', '),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsLine(String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall,
          children: <InlineSpan>[
            TextSpan(
              text: '$label: ',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  String _callModeLabel(CallConnectionMode mode) {
    return switch (mode) {
      CallConnectionMode.auto => 'Auto',
      CallConnectionMode.directPreferred => 'Direct/VPN preferred',
      CallConnectionMode.directOnly => 'Direct/VPN only',
      CallConnectionMode.relayOnly => 'Relay only',
    };
  }

  Widget _buildContactsPane(AppUser user) {
    final ThemeData theme = Theme.of(context);
    final bool compactLayout = _useCompactChatLayout(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Contacts',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_contacts.length} saved contacts',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                if (compactLayout)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _showCompactInviteSheet,
                      icon: const Icon(Icons.person_add),
                      label: const Text('Invite contact'),
                    ),
                  )
                else ...<Widget>[
                  TextField(
                    controller: _inviteUsernameController,
                    decoration: const InputDecoration(
                      hintText: 'Invite by username',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isInviteBusy ? null : _inviteByUsername,
                      icon: _isInviteBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_add),
                      label: const Text('Add contact'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _contacts.isEmpty
                ? _buildEmptyConversationState(
                    title: 'No contacts yet',
                    subtitle:
                        'Add someone by username to see them here with online status and unread counts.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: _contacts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final AppUser contact = _contacts[index];
                      return _buildContactTile(
                        currentUser: user,
                        contact: contact,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactContactsPane(AppUser user) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Contacts',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_contacts.length} saved contacts',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _showCompactInviteSheet,
                    icon: const Icon(Icons.person_add),
                    label: const Text('Invite contact'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(18),
              child: _buildEmptyConversationState(
                title: 'No contacts yet',
                subtitle:
                    'Add someone by username to see them here with online status and unread counts.',
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(10),
              itemCount: _contacts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) {
                final AppUser contact = _contacts[index];
                return _buildContactTile(
                  currentUser: user,
                  contact: contact,
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildContactTile({
    required AppUser currentUser,
    required AppUser contact,
  }) {
    final ThemeData theme = Theme.of(context);
    final int unreadCount = _messagingService.unreadCountForContact(
      currentUserId: currentUser.id,
      contactUserId: contact.id,
    );
    final bool selected = _selectedContact?.id == contact.id;

    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _selectContact(contact),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  CircleAvatar(
                    backgroundImage: contact.avatarUrl.isNotEmpty
                        ? NetworkImage(contact.avatarUrl)
                        : null,
                    child: contact.avatarUrl.isEmpty
                        ? Text(
                            contact.displayName.characters.first.toUpperCase())
                        : null,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: _buildPresenceDot(contact.status),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      contact.displayName,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (contact.quote.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        contact.quote,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _contactStatusLabel(contact),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (unreadCount > 0) _buildUnreadBadge(unreadCount),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble({
    required _ConversationEntry entry,
    required AppUser currentUser,
  }) {
    final ThemeData theme = Theme.of(context);
    final bool isMine = entry.message.fromUserId == currentUser.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                isMine
                    ? 'You'
                    : _displayNameForUserId(
                        entry.message.fromUserId,
                        fallback: _selectedContact?.displayName,
                      ),
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: isMine
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: _buildMessageContent(
                    entry.content,
                    isMine: isMine,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatMessageTimestamp(entry.message.sentAt),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageContent(
    ChatMessageContent content, {
    required bool isMine,
  }) {
    return switch (content.kind) {
      ChatMessageContentKind.text => SelectableText(content.text),
      ChatMessageContentKind.sticker => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              content.text,
              style: const TextStyle(fontSize: 46, height: 1.0),
            ),
            if (content.hasLabel) ...<Widget>[
              const SizedBox(height: 6),
              Text(content.label),
            ],
          ],
        ),
      ChatMessageContentKind.background => _buildBackgroundShareCard(content),
      ChatMessageContentKind.image || ChatMessageContentKind.gif => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildVisualMedia(content),
            if (content.hasText) ...<Widget>[
              const SizedBox(height: 8),
              Text(content.text),
            ],
          ],
        ),
      ChatMessageContentKind.video ||
      ChatMessageContentKind.audio ||
      ChatMessageContentKind.file =>
        _buildLinkedMediaCard(content, isMine: isMine),
    };
  }

  Widget _buildBackgroundShareCard(ChatMessageContent content) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildVisualMedia(content),
        const SizedBox(height: 8),
        Text(
          content.hasLabel ? content.label : 'Shared background',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: content.hasUrl
                  ? () => _applyConversationBackground(content.url)
                  : null,
              icon: const Icon(Icons.wallpaper_outlined),
              label: const Text('Apply'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed:
                  content.hasUrl ? () => _openExternalUrl(content.url) : null,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open'),
            ),
          ],
        ),
        if (content.hasUrl) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            content.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _buildVisualMedia(ChatMessageContent content) {
    if (!content.hasUrl) {
      return _buildBrokenMediaPlaceholder(
        icon: content.kind == ChatMessageContentKind.gif
            ? Icons.gif_box_outlined
            : Icons.broken_image_outlined,
        title: 'Missing media link',
        subtitle: 'This message does not contain a valid URL.',
      );
    }

    final bool isInlineData = _keyboardMediaService.isDataUrl(content.url);
    final Widget mediaWidget;
    if (isInlineData) {
      final Uint8List? data =
          _keyboardMediaService.tryDecodeDataUrl(content.url);
      if (data == null) {
        return _buildBrokenMediaPlaceholder(
          icon: content.kind == ChatMessageContentKind.gif
              ? Icons.gif_box_outlined
              : Icons.broken_image_outlined,
          title: content.kind == ChatMessageContentKind.gif
              ? 'Could not load GIF'
              : 'Could not load image',
          subtitle: 'This inline media payload is invalid.',
        );
      }
      mediaWidget = Image.memory(
        data,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      mediaWidget = Image.network(
        content.url,
        fit: BoxFit.cover,
        errorBuilder: (
          BuildContext context,
          Object error,
          StackTrace? stackTrace,
        ) {
          return _buildBrokenMediaPlaceholder(
            icon: content.kind == ChatMessageContentKind.gif
                ? Icons.gif_box_outlined
                : Icons.broken_image_outlined,
            title: content.kind == ChatMessageContentKind.gif
                ? 'Could not load GIF'
                : 'Could not load image',
            subtitle: content.url,
          );
        },
      );
    }

    final Widget clippedMedia = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 280,
          maxHeight: 260,
        ),
        child: mediaWidget,
      ),
    );

    if (isInlineData) {
      return clippedMedia;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openExternalUrl(content.url),
      child: clippedMedia,
    );
  }

  Widget _buildLinkedMediaCard(
    ChatMessageContent content, {
    required bool isMine,
  }) {
    final ThemeData theme = Theme.of(context);
    final (IconData, String) meta = switch (content.kind) {
      ChatMessageContentKind.video => (Icons.play_circle_outline, 'Video'),
      ChatMessageContentKind.audio => (Icons.audiotrack_outlined, 'Audio'),
      ChatMessageContentKind.file => (Icons.insert_drive_file_outlined, 'File'),
      _ => (Icons.link_outlined, 'Media'),
    };
    final String headline = content.hasLabel
        ? content.label
        : (content.hasText ? content.text : meta.$2);

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openExternalUrl(content.url),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(
            alpha: isMine ? 0.4 : 0.8,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: <Widget>[
            Icon(meta.$1),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    headline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta.$2,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (content.url.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      content.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.open_in_new),
          ],
        ),
      ),
    );
  }

  Widget _buildBrokenMediaPlaceholder({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 34),
          const SizedBox(height: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _openExternalUrl(String rawUrl) async {
    final Uri? uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme) {
      _showAuthMessage('This media link is not valid.');
      return;
    }

    final bool launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      _showAuthMessage('Could not open that media link.');
    }
  }

  Widget _buildEmptyConversationState({
    required String title,
    required String subtitle,
  }) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.chat_bubble_outline,
              size: 34,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnreadBadge(int unreadCount) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        unreadCount > 99 ? '99+' : unreadCount.toString(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildPresenceDot(PresenceStatus status) {
    final Color color = switch (status) {
      PresenceStatus.online => Colors.green,
      PresenceStatus.busy => Colors.orange,
      PresenceStatus.offline => Colors.grey,
    };

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  String _contactStatusLabel(AppUser contact) {
    return switch (contact.status) {
      PresenceStatus.online => 'Online now',
      PresenceStatus.busy => 'Busy',
      PresenceStatus.offline => contact.lastSeenAt == null
          ? 'Offline'
          : 'Last active ${_relativeLastSeen(contact.lastSeenAt!)}',
    };
  }

  String _relativeLastSeen(DateTime value) {
    final Duration delta = DateTime.now().difference(value);
    if (delta.inSeconds < 60) {
      return 'just now';
    }
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes}m ago';
    }
    if (delta.inHours < 24) {
      return '${delta.inHours}h ago';
    }
    return '${delta.inDays}d ago';
  }

  String _formatMessageTimestamp(DateTime value) {
    final DateTime localValue = value.toLocal();
    final String hour = localValue.hour.toString().padLeft(2, '0');
    final String minute = localValue.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
