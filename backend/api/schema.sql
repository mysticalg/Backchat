CREATE TABLE IF NOT EXISTS users (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    username VARCHAR(24) NOT NULL,
    normalized_username VARCHAR(24) NOT NULL,
    recovery_email VARCHAR(255) NOT NULL,
    avatar_url TEXT NULL,
    quote_text VARCHAR(160) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_users_normalized_username (normalized_username),
    UNIQUE KEY uniq_users_recovery_email (recovery_email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT NULL AFTER recovery_email;
ALTER TABLE users ADD COLUMN IF NOT EXISTS quote_text VARCHAR(160) NULL AFTER avatar_url;

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
