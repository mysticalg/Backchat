import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cryptography/cryptography.dart';
import 'package:tray_manager/tray_manager.dart';

import 'models/app_user.dart';
import 'models/chat_message.dart';
import 'services/auth_service.dart';
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

class _BackchatHomePageState extends State<BackchatHomePage> with TrayListener {
  final AuthService _authService = AuthService();
  final ContactsService _contactsService = ContactsService();
  final EncryptionService _encryptionService = EncryptionService();
  final MessagingService _messagingService = MessagingService();

  AppUser? _currentUser;
  List<AppUser> _contacts = <AppUser>[];
  AppUser? _selectedContact;
  final TextEditingController _messageController = TextEditingController();
  final List<String> _conversation = <String>[];

  late final SimpleKeyPair _localKeyPair;
  SimplePublicKey? _remotePublicKey;
  SecretKey? _sharedSecret;

  @override
  void initState() {
    super.initState();
    _bootstrapCrypto();
    _configureTrayIfDesktop();
  }

  Future<void> _bootstrapCrypto() async {
    _localKeyPair = await _encryptionService.createIdentityKeyPair();
    final SimpleKeyPair remotePair = await _encryptionService.createIdentityKeyPair();
    _remotePublicKey = await remotePair.extractPublicKey();
    _sharedSecret = await _encryptionService.deriveSharedSecret(
      localPrivateKey: _localKeyPair,
      remotePublicKey: _remotePublicKey!,
    );
  }

  Future<void> _configureTrayIfDesktop() async {
    if (kIsWeb || !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;

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
    if (_currentUser == null) return;
    final List<AppUser> contacts = await _contactsService.pullContactsFor(_currentUser!);
    setState(() {
      _contacts = contacts;
      _selectedContact = contacts.isNotEmpty ? contacts.first : null;
    });
  }

  Future<void> _signInGoogle() async {
    final AppUser? user = await _authService.signInWithGoogle();
    if (user == null) return;

    setState(() => _currentUser = user);
    await _loadContacts();
  }

  Future<void> _signInFacebook() async {
    final AppUser? user = await _authService.signInWithFacebook();
    if (user == null) return;

    setState(() => _currentUser = user);
    await _loadContacts();
  }

  void _changeStatus(PresenceStatus status) {
    if (_currentUser == null) return;
    setState(() {
      _currentUser = _currentUser!.copyWith(status: status);
    });
  }

  Future<void> _sendEncryptedMessage() async {
    if (_currentUser == null || _selectedContact == null || _sharedSecret == null) return;

    final String clearText = _messageController.text.trim();
    if (clearText.isEmpty) return;

    final String cipherText = await _encryptionService.encryptText(
      plainText: clearText,
      sharedSecret: _sharedSecret!,
    );

    final ChatMessage message = ChatMessage(
      fromUserId: _currentUser!.id,
      toUserId: _selectedContact!.id,
      cipherText: cipherText,
      sentAt: DateTime.now(),
    );
    await _messagingService.send(message);

    final String decrypted = await _encryptionService.decryptText(
      encodedPayload: cipherText,
      sharedSecret: _sharedSecret!,
    );

    setState(() {
      _conversation.add('Me → ${_selectedContact!.displayName}: $decrypted');
      _messageController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? user = _currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Backchat Encrypted Messenger')),
      body: user == null ? _buildAuthView() : _buildChatView(user),
    );
  }

  Widget _buildAuthView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Sign in to start encrypted messaging'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _signInGoogle,
            icon: const Icon(Icons.login),
            label: const Text('Continue with Google'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _signInFacebook,
            icon: const Icon(Icons.facebook),
            label: const Text('Continue with Facebook'),
          ),
        ],
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
                backgroundImage: user.avatarUrl.isNotEmpty ? NetworkImage(user.avatarUrl) : null,
                child: user.avatarUrl.isEmpty ? const Icon(Icons.person) : null,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(user.displayName, style: Theme.of(context).textTheme.titleMedium)),
              DropdownButton<PresenceStatus>(
                value: user.status,
                items: PresenceStatus.values
                    .map((PresenceStatus status) => DropdownMenuItem<PresenceStatus>(
                          value: status,
                          child: Text(status.name),
                        ))
                    .toList(),
                onChanged: (PresenceStatus? value) {
                  if (value != null) _changeStatus(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Contacts (${_contacts.length})'),
          Wrap(
            spacing: 8,
            children: _contacts
                .map(
                  (AppUser c) => ChoiceChip(
                    label: Text(c.displayName),
                    selected: _selectedContact?.id == c.id,
                    onSelected: (_) => setState(() => _selectedContact = c),
                  ),
                )
                .toList(),
          ),
          const Divider(height: 24),
          Expanded(
            child: ListView.builder(
              itemCount: _conversation.length,
              itemBuilder: (BuildContext context, int index) => ListTile(
                leading: const Icon(Icons.lock),
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
                    hintText: 'Type an encrypted message',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sendEncryptedMessage,
                child: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
