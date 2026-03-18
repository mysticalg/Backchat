import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import 'models/app_user.dart';
import 'models/chat_message.dart';
import 'services/auth_service.dart';
import 'services/backchat_api_service.dart';
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

class BackchatHomePage extends StatefulWidget {
  const BackchatHomePage({super.key});

  @override
  State<BackchatHomePage> createState() => _BackchatHomePageState();
}

class _BackchatHomePageState extends State<BackchatHomePage>
    with TrayListener {
  static const Duration _messagePollInterval = Duration(seconds: 2);
  static const String _plainTextTransportMode = 'plaintext_v1';

  final AuthService _authService = AuthService();
  final ContactsService _contactsService = ContactsService();
  final EncryptionService _encryptionService = EncryptionService();
  final MessagingService _messagingService = MessagingService();

  AppUser? _currentUser;
  List<AppUser> _contacts = <AppUser>[];
  AppUser? _selectedContact;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _usernameRecoveryEmailController =
      TextEditingController();
  final TextEditingController _recoveryEmailController =
      TextEditingController();
  final TextEditingController _inviteUsernameController =
      TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final List<String> _conversation = <String>[];
  bool _isAuthBusy = false;
  bool _isInviteBusy = false;
  bool _isCheckingSocialAuth = false;
  bool _isSyncingMessages = false;
  String? _socialAuthWarning;
  Timer? _messagePollTimer;

  SecretKey? _sharedSecret;

  @override
  void initState() {
    super.initState();
    _bootstrapCrypto();
    _configureTrayIfDesktop();
    _runSocialAuthStartupCheck();
  }

  @override
  void dispose() {
    _stopMessagePolling();
    _usernameController.dispose();
    _usernameRecoveryEmailController.dispose();
    _recoveryEmailController.dispose();
    _inviteUsernameController.dispose();
    _messageController.dispose();
    super.dispose();
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
    if (currentUser == null) {
      return;
    }

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
    selectedContact ??= contacts.isNotEmpty ? contacts.first : null;

    if (!mounted) {
      return;
    }

    setState(() {
      _contacts = contacts;
      _selectedContact = selectedContact;
    });
    await _refreshConversation();
  }

  void _showAuthMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _activateUserSession(AppUser user) async {
    _stopMessagePolling();
    _messagingService.reset();

    if (!mounted) {
      return;
    }

    setState(() {
      _currentUser = user;
      _conversation.clear();
    });

    await _loadContacts();
    _startMessagePolling();
    await _syncMessages(showErrors: false);
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
        await _refreshConversation();
      }
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
    await _refreshConversation();
  }

  Future<void> _refreshConversation() async {
    final AppUser? currentUser = _currentUser;
    final AppUser? selectedContact = _selectedContact;
    if (currentUser == null || selectedContact == null) {
      if (!mounted) {
        return;
      }
      setState(() => _conversation.clear());
      return;
    }

    final List<ChatMessage> messages =
        await _messagingService.listForPair(currentUser.id, selectedContact.id);
    final List<String> renderedConversation = <String>[];

    for (final ChatMessage message in messages) {
      final bool isMine = message.fromUserId == currentUser.id;
      final String text = await _decodeMessageText(message);
      final String fromLabel = isMine
          ? 'Me'
          : _displayNameForUserId(
              message.fromUserId,
              fallback: selectedContact.displayName,
            );
      final String toLabel = isMine ? selectedContact.displayName : 'Me';
      renderedConversation.add('$fromLabel -> $toLabel: $text');
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

  Future<void> _continueWithUsername() async {
    if (_isAuthBusy) return;

    setState(() => _isAuthBusy = true);
    try {
      final UsernameSignInResult result =
          await _authService.signInOrCreateWithUsername(
        username: _usernameController.text,
        recoveryEmail: _usernameRecoveryEmailController.text,
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
              'Username created and linked to your recovery email.');
          break;
        case UsernameSignInStatus.invalidUsername:
          _showAuthMessage(
              'Choose 3-24 characters: letters, numbers, or underscore.');
          break;
        case UsernameSignInStatus.usernameNeedsRecoveryEmail:
          _showAuthMessage(
              'That username is available. Add a recovery email to claim it.');
          break;
        case UsernameSignInStatus.invalidRecoveryEmail:
          _showAuthMessage('Enter a valid recovery email address.');
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

  Future<void> _runSocialAuthStartupCheck() async {
    if (!_authService.isRemoteApiEnabled) {
      return;
    }
    setState(() => _isCheckingSocialAuth = true);
    final String? warning = await _authService.socialOAuthStartupWarning();
    if (!mounted) return;
    setState(() {
      _socialAuthWarning = warning;
      _isCheckingSocialAuth = false;
    });
  }

  Future<void> _continueWithSocial({
    required Future<AppUser?> Function() signIn,
    required String providerLabel,
  }) async {
    if (_isAuthBusy) return;

    setState(() => _isAuthBusy = true);
    try {
      _showAuthMessage(
        'Opening $providerLabel login in your browser. Complete login there, then return here.',
      );
      final AppUser? user = await signIn();
      if (user == null) {
        _showAuthMessage('$providerLabel login was cancelled.');
        return;
      }
      await _activateUserSession(user);
    } on BackchatApiException catch (e) {
      _showAuthMessage(e.message);
    } catch (_) {
      _showAuthMessage(
        '$providerLabel login failed or is not configured yet.',
      );
    } finally {
      if (mounted) {
        setState(() => _isAuthBusy = false);
      }
    }
  }

  Future<void> _continueWithGoogle() {
    return _continueWithSocial(
      signIn: _authService.signInWithGoogle,
      providerLabel: 'Google',
    );
  }

  Future<void> _continueWithFacebook() {
    return _continueWithSocial(
      signIn: _authService.signInWithFacebook,
      providerLabel: 'Facebook',
    );
  }

  Future<void> _continueWithX() {
    return _continueWithSocial(
      signIn: _authService.signInWithX,
      providerLabel: 'X',
    );
  }

  Future<void> _recoverUsername() async {
    final String? username =
        await _authService.recoverUsernameForEmail(_recoveryEmailController.text);
    if (username == null) {
      _showAuthMessage('No username found for that email.');
      return;
    }

    _usernameController.text = username;
    _showAuthMessage('Recovered username: $username');
  }

  Future<void> _inviteByUsername() async {
    if (_currentUser == null || _isInviteBusy) return;

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
              '${result.contact?.displayName} is already in your contacts.');
          break;
        case InviteByUsernameStatus.selfInvite:
          _showAuthMessage('You cannot add your own username as a contact.');
          break;
        case InviteByUsernameStatus.notFound:
          _showAuthMessage('No account found with that username.');
          break;
        case InviteByUsernameStatus.invalidUsername:
          _showAuthMessage(
              'Enter a valid username (3-24 letters/numbers/underscore).');
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

  void _changeStatus(PresenceStatus status) {
    if (_currentUser == null) return;
    setState(() {
      _currentUser = _currentUser!.copyWith(status: status);
    });
  }

  /// Used only for the local encryption demo path when the shared backend is
  /// unavailable.
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

    final ChatMessage message = ChatMessage(
      fromUserId: currentUser.id,
      toUserId: selectedContact.id,
      cipherText: cipherText,
      sentAt: DateTime.now(),
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
    await _refreshConversation();
    await _syncMessages(showErrors: false);
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? user = _currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Backchat Messenger')),
      body: user == null ? _buildAuthView() : _buildChatView(user),
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
                  'Choose username, Google, Facebook, or X to start chatting.',
                  textAlign: TextAlign.center,
                ),
                if (!_authService.isRemoteApiEnabled) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'Social login needs BACKCHAT_API_BASE_URL configured in this build.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (_authService.isRemoteApiEnabled && _isCheckingSocialAuth)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (_socialAuthWarning != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _socialAuthWarning!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isAuthBusy ? null : _continueWithGoogle,
                  icon: const Icon(Icons.g_mobiledata),
                  label: const Text('Continue with Google'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _isAuthBusy ? null : _continueWithFacebook,
                  icon: const Icon(Icons.facebook),
                  label: const Text('Continue with Facebook'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _isAuthBusy ? null : _continueWithX,
                  icon: const Icon(Icons.alternate_email),
                  label: const Text('Continue with X'),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Or use username',
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
                    labelText: 'Recovery email (required for new usernames)',
                    border: OutlineInputBorder(),
                  ),
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

  Widget _buildChatView(AppUser user) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                backgroundImage:
                    user.avatarUrl.isNotEmpty ? NetworkImage(user.avatarUrl) : null,
                child: user.avatarUrl.isEmpty ? const Icon(Icons.person) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  user.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              DropdownButton<PresenceStatus>(
                value: user.status,
                items: PresenceStatus.values
                    .map(
                      (PresenceStatus status) => DropdownMenuItem<PresenceStatus>(
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
            ],
          ),
          const SizedBox(height: 12),
          Text('Contacts (${_contacts.length})'),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _inviteUsernameController,
                  decoration: const InputDecoration(
                    hintText: 'Invite by username',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _isInviteBusy ? null : _inviteByUsername,
                icon: _isInviteBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add),
                label: const Text('Invite'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_messagingService.isRemoteTransportEnabled)
            Text(
              'Messages sync through the shared backend in this build.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_messagingService.isRemoteTransportEnabled)
            const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: _contacts
                .map(
                  (AppUser contact) => ChoiceChip(
                    label: Text(contact.displayName),
                    selected: _selectedContact?.id == contact.id,
                    onSelected: (_) => _selectContact(contact),
                  ),
                )
                .toList(),
          ),
          const Divider(height: 24),
          Expanded(
            child: ListView.builder(
              itemCount: _conversation.length,
              itemBuilder: (BuildContext context, int index) => ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(_conversation[index]),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _messageController,
                  decoration: const InputDecoration(
                    hintText: 'Type a message',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Send message',
                child: FilledButton.icon(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
