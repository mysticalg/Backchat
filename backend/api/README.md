# Backchat PHP API

This folder contains a lightweight PHP + MySQL API for:

- Username sign in/create with optional passwords
- Recovery email username lookup
- Invite by username
- Contact sync
- Basic encrypted message relay endpoints
- WebRTC call signaling for one-to-one voice/video calls

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
- `call_config.php`
- `start_call.php`
- `send_call_signal.php`
- `poll_call_signals.php`
- `health.php`

## Deploy

1. Upload all files to your host folder (for example `htdocs/backchat-api`).
2. Create `config.php` on the server from `config.php.example`, or set equivalent environment variables.
    - For social login, fill provider OAuth keys:
      - `google_oauth_client_id`, `google_oauth_client_secret`, `google_oauth_redirect_uri`
      - `facebook_oauth_client_id`, `facebook_oauth_client_secret`, `facebook_oauth_redirect_uri`
      - `x_oauth_client_id`, `x_oauth_client_secret`, `x_oauth_redirect_uri`
    - Set each redirect URI to your deployed callback URL, for example:
      - `https://your-domain/backchat-api/auth_oauth_callback.php`
    - Supported environment variables:
      - `BACKCHAT_DB_HOST` or `RDS_HOSTNAME`
      - `BACKCHAT_DB_PORT` or `RDS_PORT`
      - `BACKCHAT_DB_NAME` or `RDS_DB_NAME`
      - `BACKCHAT_DB_USER` or `RDS_USERNAME`
      - `BACKCHAT_DB_PASS` or `RDS_PASSWORD`
      - `BACKCHAT_SETUP_KEY`
      - `BACKCHAT_GOOGLE_OAUTH_CLIENT_ID`, `BACKCHAT_GOOGLE_OAUTH_CLIENT_SECRET`, `BACKCHAT_GOOGLE_OAUTH_REDIRECT_URI`
      - `BACKCHAT_FACEBOOK_OAUTH_CLIENT_ID`, `BACKCHAT_FACEBOOK_OAUTH_CLIENT_SECRET`, `BACKCHAT_FACEBOOK_OAUTH_REDIRECT_URI`
      - `BACKCHAT_X_OAUTH_CLIENT_ID`, `BACKCHAT_X_OAUTH_CLIENT_SECRET`, `BACKCHAT_X_OAUTH_REDIRECT_URI`
      - Optional calling transport settings:
        - `BACKCHAT_CALL_STUN_URLS`
        - `BACKCHAT_CALL_TURN_URLS`
        - `BACKCHAT_CALL_TURN_USERNAME`
        - `BACKCHAT_CALL_TURN_CREDENTIAL`
3. Call `POST /backchat-api/setup.php` with JSON:
   - `{"setupKey":"<your setup_key>"}`
4. Use `health.php` to verify DB connectivity.

## Deploy via GitHub Actions (optional)

Workflow: `.github/workflows/deploy-backend-api.yml`

Required repo secrets:

- `AWS_ROLE_TO_ASSUME`
- `BACKCHAT_SETUP_KEY`
- Optional OAuth secrets:
  - `BACKCHAT_GOOGLE_OAUTH_CLIENT_ID`
  - `BACKCHAT_GOOGLE_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_GOOGLE_OAUTH_REDIRECT_URI`
  - `BACKCHAT_FACEBOOK_OAUTH_CLIENT_ID`
  - `BACKCHAT_FACEBOOK_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_FACEBOOK_OAUTH_REDIRECT_URI`
  - `BACKCHAT_X_OAUTH_CLIENT_ID`
  - `BACKCHAT_X_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_X_OAUTH_REDIRECT_URI`
- Optional TURN/STUN secrets for voice/video calls:
  - `BACKCHAT_CALL_STUN_URLS`
  - `BACKCHAT_CALL_TURN_URLS`
  - `BACKCHAT_CALL_TURN_USERNAME`
  - `BACKCHAT_CALL_TURN_CREDENTIAL`

Push backend changes to `main` to deploy automatically, or run the workflow manually and type `DEPLOY` in the confirmation input. Set `run_setup` to `true` only when you want the workflow to call `setup.php`.
