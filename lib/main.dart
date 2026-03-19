import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:tray_manager/tray_manager.dart';

import 'models/app_user.dart';
import 'models/call_models.dart';
import 'models/chat_message.dart';
import 'services/auth_service.dart';
import 'services/app_window_service.dart';
import 'services/backchat_api_service.dart';
import 'services/call_service.dart';
import 'services/contacts_service.dart';
import 'services/encryption_service.dart';
import 'services/messaging_service.dart';

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
    required this.text,
  });

  final ChatMessage message;
  final String text;
}

enum _CallAudioCueMode {
  none,
  incomingRinging,
  outgoingDialing,
}

class BackchatHomePage extends StatefulWidget {
  const BackchatHomePage({super.key});

  @override
  State<BackchatHomePage> createState() => _BackchatHomePageState();
}

class _BackchatHomePageState extends State<BackchatHomePage> with TrayListener {
  static const double _compactChatBreakpoint = 760;
  static const Duration _messagePollInterval = Duration(seconds: 1);
  static const Duration _contactRefreshInterval = Duration(seconds: 8);
  static const String _plainTextTransportMode = 'plaintext_v1';

  final AuthService _authService = AuthService();
  final ContactsService _contactsService = ContactsService();
  final EncryptionService _encryptionService = EncryptionService();
  final MessagingService _messagingService = MessagingService();
  final AppWindowService _appWindowService = AppWindowService();
  final CallService _callService = CallService();
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
  Timer? _messagePollTimer;
  Timer? _contactRefreshTimer;
  Timer? _callAudioCueTimer;
  _CallAudioCueMode _callAudioCueMode = _CallAudioCueMode.none;

  SecretKey? _sharedSecret;

  @override
  void initState() {
    super.initState();
    _callService.addListener(_handleCallServiceChanged);
    _bootstrapCrypto();
    _configureTrayIfDesktop();
    _loadRememberedAccounts(autofillSingleAccount: true);
  }

  @override
  void dispose() {
    _stopMessagePolling();
    _stopContactRefresh();
    _stopCallAudioCue();
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

  void _handleCallServiceChanged() {
    if (!mounted) {
      return;
    }

    final ActiveCallState callState = _callService.state;
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
        }
      }
    }
    _syncCallAudioCue(callState);
    setState(() {});
  }

  bool _useCompactChatLayout(BuildContext context) {
    return MediaQuery.sizeOf(context).width < _compactChatBreakpoint;
  }

  bool get _supportsCallAudioCue {
    return !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  }

  void _closeMobileConversation() {
    if (_selectedContact == null) {
      return;
    }
    setState(() {
      _selectedContact = null;
      _conversation.clear();
    });
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
    if (!_supportsCallAudioCue) {
      return;
    }
    await SystemSound.play(SystemSoundType.alert);
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _playOutgoingCallCueBurst() async {
    if (!_supportsCallAudioCue) {
      return;
    }
    await SystemSound.play(SystemSoundType.alert);
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
    await _messagingService.activateForUser(user.id);
    await _callService.activateForUser(user);

    if (!mounted) {
      return;
    }

    setState(() {
      _currentUser = user;
      _contacts = <AppUser>[];
      _selectedContact = null;
      _conversation.clear();
    });

    await _loadContacts();
    _startMessagePolling();
    _startContactRefresh();
    await _syncMessages(showErrors: false);
    await _syncWindowUnreadCount();
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
    await _refreshConversation(scrollToBottom: true);
    if (mounted && !_useCompactChatLayout(context)) {
      _messageFocusNode.requestFocus();
    }
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

    await _messagingService.markConversationRead(
      currentUserId: currentUser.id,
      contactUserId: selectedContact.id,
    );
    final List<ChatMessage> messages =
        await _messagingService.listForPair(currentUser.id, selectedContact.id);
    final List<_ConversationEntry> renderedConversation =
        <_ConversationEntry>[];

    for (final ChatMessage message in messages) {
      final String text = await _decodeMessageText(message);
      renderedConversation.add(
        _ConversationEntry(message: message, text: text),
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
      _scrollConversationToBottom();
    }
    await _syncWindowUnreadCount();
  }

  Future<String> _decodeMessageText(ChatMessage message) async {
    final String? plainText =
        _tryDecodePlainTextTransportPayload(message.cipherText);
    if (plainText != null) {
      return plainText;
    }

    if (_sharedSecret == null) {
      return '[Message unavailable]';
    }

    try {
      return await _encryptionService.decryptText(
        encodedPayload: message.cipherText,
        sharedSecret: _sharedSecret!,
        associatedData: _buildMessageAad(
          fromUserId: message.fromUserId,
          toUserId: message.toUserId,
        ),
      );
    } catch (_) {
      return '[Unable to read message]';
    }
  }

  String _encodePlainTextTransportPayload(String plainText) {
    return jsonEncode(<String, dynamic>{
      'mode': _plainTextTransportMode,
      'text': plainText,
    });
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

  void _scrollConversationToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_conversationScrollController.hasClients) {
        return;
      }
      final double target =
          _conversationScrollController.position.maxScrollExtent + 80;
      _conversationScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
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
            'Could not reach the server. Falling back to local mode.',
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
      await _activateUserSession(user);
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

  Future<void> _inviteByUsername() async {
    if (_currentUser == null || _isInviteBusy) {
      return;
    }

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
          break;
        case InviteByUsernameStatus.alreadyContact:
          _showAuthMessage(
            '${result.contact?.displayName} is already in your contacts.',
          );
          break;
        case InviteByUsernameStatus.selfInvite:
          _showAuthMessage('You cannot add your own username as a contact.');
          break;
        case InviteByUsernameStatus.notFound:
          _showAuthMessage('No account found with that username.');
          break;
        case InviteByUsernameStatus.invalidUsername:
          _showAuthMessage(
            'Enter a valid username (3-24 letters/numbers/underscore).',
          );
          break;
        case InviteByUsernameStatus.serverUnavailable:
          _showAuthMessage(
            'Invite service is currently unavailable. Please try again.',
          );
          break;
      }
    } catch (_) {
      _showAuthMessage('Invite failed unexpectedly. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isInviteBusy = false);
      }
    }
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

  Future<void> _sendMessage() async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      return;
    }

    final String clearText = _messageController.text.trim();
    if (clearText.isEmpty) {
      return;
    }

    late final String cipherText;
    if (_messagingService.isRemoteTransportEnabled) {
      cipherText = _encodePlainTextTransportPayload(clearText);
    } else {
      if (_sharedSecret == null) {
        return;
      }
      final List<int> aad = _buildMessageAad(
        fromUserId: currentUser.id,
        toUserId: selectedContact.id,
      );
      cipherText = await _encryptionService.encryptText(
        plainText: clearText,
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

    _messageController.clear();
    await _refreshConversation(scrollToBottom: true);
    await _syncMessages(showErrors: false);
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? user = _currentUser;
    final bool compactLayout =
        user != null && _useCompactChatLayout(context);
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
          actions: showingMobileConversation
              ? _buildMobileConversationAppBarActions(_selectedContact!)
              : null,
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
            child: _buildConversationPane(user),
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
        onPressed: anotherCallIsActive ? null : () => _startCall(CallKind.audio),
        icon: const Icon(Icons.call_outlined),
      ),
      IconButton(
        tooltip: 'Video call',
        onPressed: anotherCallIsActive ? null : () => _startCall(CallKind.video),
        icon: const Icon(Icons.videocam_outlined),
      ),
    ];
  }

  Widget _buildCompactContactsView(AppUser user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildCompactUserCard(user),
        if (!_callService.state.isIdle) ...<Widget>[
          const SizedBox(height: 12),
          _buildCallPanel(),
        ],
        const SizedBox(height: 12),
        Expanded(child: _buildContactsPane(user)),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: _buildCompactContactBanner(selectedContact),
          ),
          if (!_callService.state.isIdle) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildCallPanel(),
            ),
            const SizedBox(height: 12),
          ],
          if (_messagingService.isRemoteTransportEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Messages sync through AWS while history is also cached locally on this device.',
                style: theme.textTheme.bodySmall,
              ),
            ),
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
                  child: user.avatarUrl.isEmpty
                      ? const Icon(Icons.person)
                      : null,
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
          ],
        ),
      ),
    );
  }

  Widget _buildCompactContactBanner(AppUser contact) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        CircleAvatar(
          radius: 22,
          backgroundImage:
              contact.avatarUrl.isNotEmpty ? NetworkImage(contact.avatarUrl) : null,
          child: contact.avatarUrl.isEmpty
              ? Text(contact.displayName.characters.first.toUpperCase())
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                contact.displayName,
                style: theme.textTheme.titleMedium,
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
              Row(
                children: <Widget>[
                  _buildPresenceDot(contact.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _contactStatusLabel(contact),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConversationBody({
    required AppUser user,
    required AppUser? selectedContact,
  }) {
    if (selectedContact == null) {
      return _buildEmptyConversationState(
        title: 'Open a conversation',
        subtitle:
            'Select a contact from the contact list to load previous messages and start chatting.',
      );
    }

    if (_conversation.isEmpty) {
      return _buildEmptyConversationState(
        title: 'No messages yet',
        subtitle:
            'Your conversation history is stored locally on this device once you start chatting.',
      );
    }

    return ListView.builder(
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

    final Widget composerField = TextField(
      controller: _messageController,
      focusNode: _messageFocusNode,
      onSubmitted: (_) => _sendMessage(),
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
      onPressed: selectedContact == null ? null : _sendMessage,
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
                emojiButton,
                const SizedBox(width: 2),
                sendButton,
              ],
            ),
    );
  }

  Widget _buildConversationPane(AppUser user) {
    final AppUser? selectedContact = _selectedContact;
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    CircleAvatar(
                      backgroundImage: user.avatarUrl.isNotEmpty
                          ? NetworkImage(user.avatarUrl)
                          : null,
                      child: user.avatarUrl.isEmpty
                          ? const Icon(Icons.person)
                          : null,
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
                    IconButton(
                      tooltip: 'Call routing settings',
                      onPressed: _editCallSettings,
                      icon: const Icon(Icons.settings_ethernet_outlined),
                    ),
                    IconButton(
                      tooltip: 'Edit profile',
                      onPressed: _editProfile,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    DropdownButtonHideUnderline(
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
                  ],
                ),
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: selectedContact == null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'No contact selected',
                                style: theme.textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Choose someone from the contact list to load your local conversation history.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          )
                        : Row(
                            children: <Widget>[
                              CircleAvatar(
                                radius: 20,
                                backgroundImage: selectedContact
                                        .avatarUrl.isNotEmpty
                                    ? NetworkImage(selectedContact.avatarUrl)
                                    : null,
                                child: selectedContact.avatarUrl.isEmpty
                                    ? Text(
                                        selectedContact
                                            .displayName.characters.first
                                            .toUpperCase(),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      selectedContact.displayName,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    if (selectedContact
                                        .quote.isNotEmpty) ...<Widget>[
                                      const SizedBox(height: 2),
                                      Text(
                                        selectedContact.quote,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Row(
                                      children: <Widget>[
                                        _buildPresenceDot(
                                            selectedContact.status),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            _contactStatusLabel(
                                                selectedContact),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                children: <Widget>[
                                  IconButton.filledTonal(
                                    tooltip: 'Start voice call',
                                    onPressed:
                                        _callService.state.isInProgress &&
                                                _callService.state.peer?.id !=
                                                    selectedContact.id
                                            ? null
                                            : () => _startCall(CallKind.audio),
                                    icon: const Icon(Icons.call_outlined),
                                  ),
                                  const SizedBox(height: 8),
                                  IconButton.filledTonal(
                                    tooltip: 'Start video call',
                                    onPressed:
                                        _callService.state.isInProgress &&
                                                _callService.state.peer?.id !=
                                                    selectedContact.id
                                            ? null
                                            : () => _startCall(CallKind.video),
                                    icon: const Icon(Icons.videocam_outlined),
                                  ),
                                ],
                              ),
                            ],
                          ),
                  ),
                ),
                if (!_callService.state.isIdle) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildCallPanel(),
                ],
                if (_messagingService.isRemoteTransportEnabled) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'Messages sync through AWS while history is also cached locally on this computer.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
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
  }

  Widget _buildCallPanel() {
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
            _buildCallMediaStage(callState),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _buildCallActionButtons(callState),
            ),
            const SizedBox(height: 12),
            _buildCallDiagnosticsBlock(
              diagnostics: callState.diagnostics,
              showTitle: false,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallMediaStage(ActiveCallState callState) {
    final ThemeData theme = Theme.of(context);
    final AppUser? peer = callState.peer;
    if (peer == null) {
      return const SizedBox.shrink();
    }

    final bool showRemoteVideo =
        callState.kind == CallKind.video && callState.hasRemoteVideo;
    return SizedBox(
      height: 220,
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
                  child: Text(entry.text),
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
