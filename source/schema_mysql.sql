-- Target: MySQL 8.0.16+ or 8.4. All DATETIME values are UTC.
-- load_mysql.py selects the database before executing this schema.
-- No DROP, DELETE, or TRUNCATE statements are used.

CREATE TABLE IF NOT EXISTS reason_codes (
  reason_code VARCHAR(48) PRIMARY KEY,
  reason_class VARCHAR(16) NOT NULL,
  system_component VARCHAR(40) NOT NULL,
  description VARCHAR(255) NOT NULL,
  retry_after_confirmed_failure VARCHAR(3) NOT NULL,
  CHECK (reason_class IN ('FAILURE', 'UNCERTAINTY')),
  CHECK (retry_after_confirmed_failure IN ('YES', 'NO'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS customers (
  customer_id VARCHAR(24) PRIMARY KEY,
  full_name VARCHAR(150) NOT NULL,
  home_city VARCHAR(50) NOT NULL,
  registered_at DATETIME(3) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS wallets_opening (
  wallet_id VARCHAR(24) PRIMARY KEY,
  customer_id VARCHAR(24) NOT NULL,
  currency CHAR(3) NOT NULL,
  status VARCHAR(12) NOT NULL,
  opening_balance_cents BIGINT NOT NULL,
  snapshot_at DATETIME(3) NOT NULL,
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
  CHECK (opening_balance_cents >= 0),
  CHECK (status IN ('ACTIVE', 'INACTIVE')),
  CHECK (currency = 'USD')
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS wallets_closing (
  wallet_id VARCHAR(24) PRIMARY KEY,
  currency CHAR(3) NOT NULL,
  snapshot_at DATETIME(3) NOT NULL,
  ledger_balance_cents BIGINT NOT NULL,
  held_balance_cents BIGINT NOT NULL,
  available_balance_cents BIGINT NOT NULL,
  FOREIGN KEY (wallet_id) REFERENCES wallets_opening(wallet_id),
  CHECK (ledger_balance_cents >= 0),
  CHECK (held_balance_cents >= 0),
  CHECK (available_balance_cents >= 0),
  CHECK (ledger_balance_cents = held_balance_cents + available_balance_cents)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS payment_requests (
  payment_id VARCHAR(24) PRIMARY KEY,
  requested_at DATETIME(3) NOT NULL,
  sender_wallet_id VARCHAR(24) NOT NULL,
  recipient_wallet_id VARCHAR(24) NOT NULL,
  amount_cents BIGINT NOT NULL,
  currency CHAR(3) NOT NULL,
  payment_type VARCHAR(10) NOT NULL,
  channel VARCHAR(10) NOT NULL,
  origin_city VARCHAR(50) NOT NULL,
  FOREIGN KEY (sender_wallet_id) REFERENCES wallets_opening(wallet_id),
  FOREIGN KEY (recipient_wallet_id) REFERENCES wallets_opening(wallet_id),
  CHECK (amount_cents > 0),
  CHECK (sender_wallet_id <> recipient_wallet_id),
  CHECK (payment_type = 'P2P'),
  CHECK (channel IN ('USSD', 'APP')),
  INDEX ix_request_time (requested_at, payment_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS payment_attempts (
  attempt_id VARCHAR(32) PRIMARY KEY,
  payment_id VARCHAR(24) NOT NULL,
  attempt_number INT NOT NULL,
  started_at DATETIME(3) NOT NULL,
  available_balance_cents_at_start BIGINT NOT NULL,
  FOREIGN KEY (payment_id) REFERENCES payment_requests(payment_id),
  UNIQUE KEY uq_payment_attempt_number (payment_id, attempt_number),
  CHECK (attempt_number >= 1),
  CHECK (available_balance_cents_at_start >= 0),
  INDEX ix_attempt_start (started_at, attempt_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS system_incidents (
  incident_id VARCHAR(24) PRIMARY KEY,
  started_at DATETIME(3) NOT NULL,
  ended_at DATETIME(3) NOT NULL,
  affected_city VARCHAR(50) NOT NULL,
  affected_channel VARCHAR(10) NOT NULL,
  incident_type VARCHAR(60) NOT NULL,
  recorded_by VARCHAR(24) NOT NULL,
  CHECK (ended_at >= started_at),
  CHECK (recorded_by = 'SYSTEM_MONITOR')
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS event_deliveries (
  source_row_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  event_id VARCHAR(24) NOT NULL,
  payment_id VARCHAR(24) NOT NULL,
  attempt_id VARCHAR(32) NOT NULL,
  event_at DATETIME(3) NOT NULL,
  status VARCHAR(12) NOT NULL,
  reason_code VARCHAR(48) NULL,
  reason_source VARCHAR(12) NULL,
  system_component VARCHAR(40) NOT NULL,
  incident_id VARCHAR(24) NULL,
  delivery_id VARCHAR(24) NOT NULL,
  ingested_at DATETIME(3) NOT NULL,
  UNIQUE KEY uq_delivery_id (delivery_id),
  FOREIGN KEY (payment_id) REFERENCES payment_requests(payment_id),
  FOREIGN KEY (attempt_id) REFERENCES payment_attempts(attempt_id),
  FOREIGN KEY (reason_code) REFERENCES reason_codes(reason_code),
  FOREIGN KEY (incident_id) REFERENCES system_incidents(incident_id),
  CHECK (status IN ('REQUESTED', 'PENDING', 'SUCCEEDED', 'FAILED')),
  CHECK (reason_source IS NULL OR reason_source = 'SYSTEM'),
  CHECK ((reason_code IS NULL AND reason_source IS NULL) OR (reason_code IS NOT NULL AND reason_source IS NOT NULL AND reason_source = 'SYSTEM')),
  CHECK (ingested_at >= event_at),
  INDEX ix_event_id (event_id),
  INDEX ix_attempt_event_time (attempt_id, event_at),
  INDEX ix_ingestion_time (ingested_at, source_row_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ledger_entries (
  entry_id VARCHAR(24) PRIMARY KEY,
  payment_id VARCHAR(24) NOT NULL,
  attempt_id VARCHAR(32) NOT NULL,
  wallet_id VARCHAR(24) NOT NULL,
  posted_at DATETIME(3) NOT NULL,
  signed_amount_cents BIGINT NOT NULL,
  currency CHAR(3) NOT NULL,
  entry_type VARCHAR(20) NOT NULL,
  FOREIGN KEY (payment_id) REFERENCES payment_requests(payment_id),
  FOREIGN KEY (attempt_id) REFERENCES payment_attempts(attempt_id),
  FOREIGN KEY (wallet_id) REFERENCES wallets_opening(wallet_id),
  CHECK (signed_amount_cents <> 0),
  CHECK ((entry_type = 'TRANSFER_OUT' AND signed_amount_cents < 0)
      OR (entry_type = 'TRANSFER_IN' AND signed_amount_cents > 0)),
  INDEX ix_ledger_posted (posted_at, entry_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dataset_metadata (
  metadata_key VARCHAR(50) PRIMARY KEY,
  metadata_json JSON NOT NULL
) ENGINE=InnoDB;
