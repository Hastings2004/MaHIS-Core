-- Database accounts every MaHIS server in this deployment has (rights are
-- set later by `rake site_sync:grants`):
--   mahis_app   the MaHIS API
--   mahis_sync  the sync agent; the capture triggers run as this account
CREATE USER IF NOT EXISTS 'mahis_app'@'%' IDENTIFIED BY 'app';
CREATE USER IF NOT EXISTS 'mahis_sync'@'%' IDENTIFIED BY 'sync';
