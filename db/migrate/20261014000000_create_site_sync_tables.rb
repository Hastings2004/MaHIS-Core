# frozen_string_literal: true

# Bookkeeping tables for two-way site <-> central sync (prototype).
# Every node gets all tables; a site only uses the "site" ones and central only
# the "central" ones. Capture triggers are not created here: they are generated
# from config/site_sync_tables.yml and installed on sites with
# `rake site_sync:install`.
class CreateSiteSyncTables < ActiveRecord::Migration[7.0]
  def up
    # ---- site side -------------------------------------------------------
    execute <<~SQL
      CREATE TABLE sync_state (
        name VARCHAR(64) NOT NULL PRIMARY KEY,
        value TEXT NULL,
        updated_at DATETIME(6) NOT NULL
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # The outbox. Written only by the capture triggers, in the same transaction
    # as the clinical write. batch_id is NULL until the agent seals the row.
    execute <<~SQL
      CREATE TABLE sync_change_log (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        lane VARCHAR(16) NOT NULL,
        batch_id BIGINT NULL,
        table_name VARCHAR(64) NOT NULL,
        op CHAR(1) NOT NULL,
        row_pk BIGINT NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        before_json JSON NULL,
        after_json JSON NULL,
        row_hash CHAR(64) NULL,
        origin VARCHAR(8) NOT NULL,
        request_id VARCHAR(64) NULL,
        endpoint VARCHAR(160) NULL,
        job VARCHAR(160) NULL,
        user_uuid CHAR(38) NULL,
        captured_at DATETIME(6) NOT NULL,
        KEY idx_sync_change_log_unsealed (batch_id, lane, id),
        KEY idx_sync_change_log_row (table_name, row_uuid),
        KEY idx_sync_change_log_request (request_id)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_batches (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        lane VARCHAR(16) NOT NULL,
        epoch INT NOT NULL,
        seq BIGINT NOT NULL,
        first_log_id BIGINT NOT NULL,
        last_log_id BIGINT NOT NULL,
        event_count INT NOT NULL,
        prev_hash CHAR(64) NOT NULL,
        batch_hash CHAR(64) NOT NULL,
        payload LONGBLOB NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'sealed',
        attempts INT NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        ack_json JSON NULL,
        created_at DATETIME(6) NOT NULL,
        acked_at DATETIME(6) NULL,
        UNIQUE KEY idx_sync_batches_lane_seq (epoch, lane, seq),
        KEY idx_sync_batches_status (status, lane, seq)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_pending_apply (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        gseq BIGINT NULL,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        event_json JSON NOT NULL,
        attempts INT NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at DATETIME(6) NOT NULL
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_quarantine_notices (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        event_id VARCHAR(80) NOT NULL,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        reason VARCHAR(64) NOT NULL,
        details TEXT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'open',
        created_at DATETIME(6) NOT NULL,
        resolved_at DATETIME(6) NULL,
        UNIQUE KEY idx_sync_quarantine_notices_event (event_id),
        KEY idx_sync_quarantine_notices_row (row_uuid, status)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # ---- both sides ------------------------------------------------------
    # Newest change applied per row, so an older event that arrives late (for
    # example a pull that overlaps an on-demand patient fetch) never wins.
    execute <<~SQL
      CREATE TABLE sync_row_versions (
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        hlc BIGINT NOT NULL,
        site_code VARCHAR(16) NOT NULL,
        PRIMARY KEY (table_name, row_uuid)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_reconciliation_runs (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        site_code VARCHAR(16) NOT NULL,
        status VARCHAR(16) NOT NULL,
        report_json JSON NULL,
        bytes_exchanged BIGINT NOT NULL DEFAULT 0,
        started_at DATETIME(6) NOT NULL,
        finished_at DATETIME(6) NULL
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # ---- central side ----------------------------------------------------
    execute <<~SQL
      CREATE TABLE sync_sites (
        site_code VARCHAR(16) NOT NULL PRIMARY KEY,
        name VARCHAR(128) NOT NULL,
        secret VARCHAR(128) NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'active',
        epoch INT NOT NULL DEFAULT 1,
        restore_point_gseq BIGINT NULL,
        last_heartbeat_at DATETIME(6) NULL,
        heartbeat_json JSON NULL,
        created_at DATETIME(6) NOT NULL,
        updated_at DATETIME(6) NOT NULL
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_site_lanes (
        site_code VARCHAR(16) NOT NULL,
        epoch INT NOT NULL,
        lane VARCHAR(16) NOT NULL,
        committed_seq BIGINT NOT NULL DEFAULT 0,
        last_batch_hash CHAR(64) NOT NULL,
        updated_at DATETIME(6) NOT NULL,
        PRIMARY KEY (site_code, epoch, lane)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # Stored acknowledgements, so a batch resent after a lost ack gets the
    # same answer without being applied twice.
    execute <<~SQL
      CREATE TABLE sync_received_batches (
        site_code VARCHAR(16) NOT NULL,
        epoch INT NOT NULL,
        lane VARCHAR(16) NOT NULL,
        seq BIGINT NOT NULL,
        batch_hash CHAR(64) NOT NULL,
        event_count INT NOT NULL,
        ack_json JSON NOT NULL,
        received_at DATETIME(6) NOT NULL,
        PRIMARY KEY (site_code, epoch, lane, seq)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # Exact copy of every site's rows, with the site's own local ids. This is
    # the national backup: restores and nightly reconciliation read it.
    execute <<~SQL
      CREATE TABLE sync_site_mirror (
        site_code VARCHAR(16) NOT NULL,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        local_id BIGINT NOT NULL,
        row_json JSON NOT NULL,
        row_hash CHAR(64) NOT NULL,
        hlc BIGINT NOT NULL,
        deleted TINYINT NOT NULL DEFAULT 0,
        updated_at DATETIME(6) NOT NULL,
        PRIMARY KEY (site_code, table_name, row_uuid),
        KEY idx_sync_site_mirror_local (site_code, table_name, local_id)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_row_owners (
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        site_code VARCHAR(16) NOT NULL,
        PRIMARY KEY (table_name, row_uuid)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_field_versions (
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        column_name VARCHAR(64) NOT NULL,
        hlc BIGINT NOT NULL,
        site_code VARCHAR(16) NOT NULL,
        PRIMARY KEY (table_name, row_uuid, column_name)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_conflicts (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        column_name VARCHAR(64) NOT NULL,
        kind VARCHAR(16) NOT NULL,
        kept_value TEXT NULL,
        kept_site VARCHAR(16) NULL,
        kept_hlc BIGINT NULL,
        losing_value TEXT NULL,
        losing_site VARCHAR(16) NULL,
        losing_hlc BIGINT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'open',
        created_at DATETIME(6) NOT NULL,
        KEY idx_sync_conflicts_row (table_name, row_uuid)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_quarantine (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        site_code VARCHAR(16) NOT NULL,
        event_id VARCHAR(80) NOT NULL,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        request_id VARCHAR(64) NULL,
        reason VARCHAR(64) NOT NULL,
        details TEXT NULL,
        parent_uuid CHAR(38) NULL,
        event_json JSON NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'open',
        created_at DATETIME(6) NOT NULL,
        resolved_at DATETIME(6) NULL,
        UNIQUE KEY idx_sync_quarantine_event (site_code, event_id),
        KEY idx_sync_quarantine_row (row_uuid, status),
        KEY idx_sync_quarantine_parent (parent_uuid, status)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # The downstream feed. gseq is assigned under a lock in commit order, so
    # a site reading "everything after my cursor" can never skip a row.
    execute <<~SQL
      CREATE TABLE sync_central_log (
        gseq BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        origin_site VARCHAR(16) NOT NULL,
        target_site VARCHAR(16) NULL,
        table_name VARCHAR(64) NOT NULL,
        op CHAR(1) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        patient_uuid CHAR(38) NULL,
        hlc BIGINT NOT NULL,
        event_json JSON NOT NULL,
        created_at DATETIME(6) NOT NULL,
        KEY idx_sync_central_log_patient (patient_uuid, gseq),
        KEY idx_sync_central_log_target (target_site, gseq)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_subscriptions (
        site_code VARCHAR(16) NOT NULL,
        patient_uuid CHAR(38) NOT NULL,
        reason VARCHAR(32) NOT NULL,
        created_at DATETIME(6) NOT NULL,
        PRIMARY KEY (site_code, patient_uuid),
        KEY idx_sync_subscriptions_patient (patient_uuid)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_deleted_records (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        site_code VARCHAR(16) NOT NULL,
        table_name VARCHAR(64) NOT NULL,
        row_uuid CHAR(38) NOT NULL,
        row_json JSON NULL,
        deleted_at DATETIME(6) NOT NULL,
        KEY idx_sync_deleted_records_row (table_name, row_uuid)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    # One-time values of accepted site requests, so none can be replayed.
    execute <<~SQL
      CREATE TABLE sync_request_nonces (
        nonce CHAR(32) NOT NULL PRIMARY KEY,
        site_code VARCHAR(16) NOT NULL,
        site_timestamp BIGINT NULL,
        seen_at DATETIME(6) NOT NULL,
        KEY idx_sync_request_nonces_seen (seen_at)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL

    execute <<~SQL
      CREATE TABLE sync_alerts (
        id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        site_code VARCHAR(16) NULL,
        kind VARCHAR(48) NOT NULL,
        message TEXT NOT NULL,
        created_at DATETIME(6) NOT NULL,
        KEY idx_sync_alerts_site (site_code, created_at)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
    SQL
  end

  def down
    %w[sync_alerts sync_request_nonces sync_deleted_records sync_subscriptions sync_central_log sync_quarantine
       sync_conflicts sync_field_versions sync_row_owners sync_site_mirror sync_received_batches
       sync_site_lanes sync_sites sync_reconciliation_runs sync_row_versions
       sync_quarantine_notices sync_pending_apply sync_batches sync_change_log sync_state].each do |table|
      execute "DROP TABLE IF EXISTS #{table}"
    end
  end
end
