# Backchat PHP API

This folder contains a lightweight PHP + MySQL API for:

- Username sign in/create (passwordless)
- Recovery email username lookup
- Invite by username
- Contact sync
- Basic encrypted message relay endpoints

## Files

- `config.php.example`: Copy to `config.php` and fill credentials/secrets.
- `schema.sql`: Database tables.
- `setup.php`: One-time schema installer endpoint (protected by `setup_key`).
- `auth_username.php`
- `recover_username.php`
- `invite_by_username.php`
- `contacts.php`
- `send_message.php`
- `poll_messages.php`
- `health.php`

## Deploy

1. Upload all files to your host folder (for example `htdocs/backchat-api`).
2. Create `config.php` on the server from `config.php.example`.
3. Call `POST /backchat-api/setup.php` with JSON:
   - `{"setupKey":"<your setup_key>"}`
4. Use `health.php` to verify DB connectivity.
