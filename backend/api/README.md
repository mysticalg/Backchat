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
- `auth_oauth_start.php`
- `auth_oauth_callback.php`
- `auth_oauth_poll.php`
- `oauth_probe.php`
- `recover_username.php`
- `invite_by_username.php`
- `contacts.php`
- `send_message.php`
- `poll_messages.php`
- `health.php`

## Deploy

1. Upload all files to your host folder (for example `htdocs/backchat-api`).
2. Create `config.php` on the server from `config.php.example`.
   - For social login, fill provider OAuth keys:
     - `google_oauth_client_id`, `google_oauth_client_secret`, `google_oauth_redirect_uri`
     - `facebook_oauth_client_id`, `facebook_oauth_client_secret`, `facebook_oauth_redirect_uri`
     - `x_oauth_client_id`, `x_oauth_client_secret`, `x_oauth_redirect_uri`
   - Set each redirect URI to your deployed callback URL, for example:
     - `https://your-domain/backchat-api/auth_oauth_callback.php`
3. Call `POST /backchat-api/setup.php` with JSON:
   - `{"setupKey":"<your setup_key>"}`
4. Use `health.php` to verify DB connectivity.

## Deploy via GitHub Actions (optional)

Workflow: `.github/workflows/deploy-backend-api.yml`

Required repo secrets:

- `BACKEND_FTP_SERVER`
- `BACKEND_FTP_USERNAME`
- `BACKEND_FTP_PASSWORD`
- `BACKEND_FTP_SERVER_DIR`

When you run the workflow manually, type `DEPLOY` in the confirmation input.
