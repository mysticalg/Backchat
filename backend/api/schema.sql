CREATE TABLE IF NOT EXISTS users (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    username VARCHAR(24) NOT NULL,
    normalized_username VARCHAR(24) NOT NULL,
    recovery_email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NULL,
    password_updated_at DATETIME NULL,
    avatar_url TEXT NULL,
    quote_text VARCHAR(160) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_users_normalized_username (normalized_username),
    UNIQUE KEY uniq_users_recovery_email (recovery_email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id BIGINT UNSIGNED NOT NULL,
    token_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at DATETIME NULL,
    expires_at DATETIME NULL,
    revoked_at DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_sessions_token_hash (token_hash),
    KEY idx_sessions_user_id (user_id),
    CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS oauth_identities (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id BIGINT UNSIGNED NOT NULL,
    provider ENUM('google', 'facebook', 'x') NOT NULL,
    provider_user_id VARCHAR(128) NOT NULL,
    provider_username VARCHAR(128) NULL,
    display_name VARCHAR(255) NULL,
    email VARCHAR(255) NULL,
    avatar_url TEXT NULL,
    access_token TEXT NOT NULL,
    refresh_token TEXT NULL,
    token_type VARCHAR(32) NULL,
    scope TEXT NULL,
    token_expires_at DATETIME NULL,
    raw_profile_json MEDIUMTEXT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_oauth_provider_user (provider, provider_user_id),
    UNIQUE KEY uniq_oauth_user_provider (user_id, provider),
    KEY idx_oauth_user_id (user_id),
    CONSTRAINT fk_oauth_identity_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS oauth_pending_states (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider ENUM('google', 'facebook', 'x') NOT NULL,
    state VARCHAR(128) NOT NULL,
    code_verifier VARCHAR(256) NOT NULL,
    status ENUM('pending', 'completed', 'failed') NOT NULL DEFAULT 'pending',
    error_code VARCHAR(64) NULL,
    user_id BIGINT UNSIGNED NULL,
    session_token TEXT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at DATETIME NULL,
    expires_at DATETIME NOT NULL,
    consumed_at DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_oauth_state (state),
    KEY idx_oauth_pending_provider (provider),
    KEY idx_oauth_pending_status (status),
    KEY idx_oauth_pending_user_id (user_id),
    CONSTRAINT fk_oauth_pending_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS contacts (
    user_id BIGINT UNSIGNED NOT NULL,
    contact_user_id BIGINT UNSIGNED NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, contact_user_id),
    KEY idx_contacts_contact_user_id (contact_user_id),
    CONSTRAINT fk_contacts_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_contacts_contact_user FOREIGN KEY (contact_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    sender_user_id BIGINT UNSIGNED NOT NULL,
    recipient_user_id BIGINT UNSIGNED NOT NULL,
    ciphertext MEDIUMTEXT NOT NULL,
    client_message_id VARCHAR(64) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivered_at DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_messages_sender_client_id (sender_user_id, client_message_id),
    KEY idx_messages_recipient_id_id (recipient_user_id, id),
    KEY idx_messages_sender_id_id (sender_user_id, id),
    CONSTRAINT fk_messages_sender_user FOREIGN KEY (sender_user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_messages_recipient_user FOREIGN KEY (recipient_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS message_media (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    owner_user_id BIGINT UNSIGNED NOT NULL,
    media_key VARCHAR(64) NOT NULL,
    media_kind ENUM('image', 'gif') NOT NULL,
    mime_type VARCHAR(64) NOT NULL,
    original_name VARCHAR(255) NULL,
    byte_size INT UNSIGNED NOT NULL,
    blob_data MEDIUMBLOB NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_message_media_key (media_key),
    KEY idx_message_media_owner_created (owner_user_id, created_at),
    CONSTRAINT fk_message_media_owner_user FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS message_media_uploads (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    owner_user_id BIGINT UNSIGNED NOT NULL,
    upload_token VARCHAR(64) NOT NULL,
    declared_mime_type VARCHAR(64) NOT NULL,
    original_name VARCHAR(255) NULL,
    total_bytes INT UNSIGNED NOT NULL DEFAULT 0,
    next_chunk_index INT UNSIGNED NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_message_media_upload_token (upload_token),
    KEY idx_message_media_upload_owner_updated (owner_user_id, updated_at),
    CONSTRAINT fk_message_media_upload_owner_user FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS message_media_upload_chunks (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    upload_id BIGINT UNSIGNED NOT NULL,
    chunk_index INT UNSIGNED NOT NULL,
    chunk_size SMALLINT UNSIGNED NOT NULL,
    chunk_data BLOB NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_message_media_upload_chunk (upload_id, chunk_index),
    KEY idx_message_media_upload_chunks_upload_id (upload_id),
    CONSTRAINT fk_message_media_upload_chunk_upload FOREIGN KEY (upload_id) REFERENCES message_media_uploads(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS call_sessions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    caller_user_id BIGINT UNSIGNED NOT NULL,
    callee_user_id BIGINT UNSIGNED NOT NULL,
    kind ENUM('audio', 'video') NOT NULL,
    status ENUM('ringing', 'active', 'ended', 'rejected', 'busy', 'cancelled', 'failed') NOT NULL DEFAULT 'ringing',
    preferences_json TEXT NULL,
    answered_at DATETIME NULL,
    ended_at DATETIME NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_call_sessions_caller_status (caller_user_id, status),
    KEY idx_call_sessions_callee_status (callee_user_id, status),
    CONSTRAINT fk_call_sessions_caller_user FOREIGN KEY (caller_user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_call_sessions_callee_user FOREIGN KEY (callee_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS call_signal_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    call_session_id BIGINT UNSIGNED NOT NULL,
    sender_user_id BIGINT UNSIGNED NOT NULL,
    recipient_user_id BIGINT UNSIGNED NOT NULL,
    event_type ENUM('offer', 'answer', 'candidate', 'ringing', 'rejected', 'ended', 'busy') NOT NULL,
    payload_json MEDIUMTEXT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_call_signal_recipient_id_id (recipient_user_id, id),
    KEY idx_call_signal_session_id_id (call_session_id, id),
    CONSTRAINT fk_call_signal_session FOREIGN KEY (call_session_id) REFERENCES call_sessions(id) ON DELETE CASCADE,
    CONSTRAINT fk_call_signal_sender_user FOREIGN KEY (sender_user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_call_signal_recipient_user FOREIGN KEY (recipient_user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
