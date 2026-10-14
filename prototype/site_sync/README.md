# Two-way site ↔ central sync: prototype

A working prototype of the design in *MaHIS Two-Way Site–Central Synchronization*.
Two sites and central are full MaHIS-Core instances (same codebase, different
`MAHIS_SYNC_ROLE`); the demo drives them through the real MaHIS API and
checks the result on all three databases.

Scope: `person`, `patient`, `person_name`, `patient_identifier`, `encounter`,
`obs`. Reference data (concepts, users, locations, programs) is seeded
identically on every node and not synced yet.

## Run it

Needs WSL/Linux with MySQL 8 server binaries, Ruby (rbenv) and the app's gems.
Nothing touches your main MySQL: the prototype starts its own on port 3307,
with data under `tmp/site_sync_mysql/`.

```bash
cd MaHIS-Core
SOURCE_PASSWORD=... prototype/site_sync/bin/setup   # copies your dev DB into 3 databases (once)
prototype/site_sync/bin/start                       # central :3200, site A :3201, site B :3202, links, agents
bundle exec ruby prototype/site_sync/demo/run.rb    # all scenes; or name one: ... run.rb conflict
prototype/site_sync/bin/stop
```

Dashboard: <http://127.0.0.1:3200/api/v1/site_sync/admin/dashboard?token=demo-admin-token>

Link control while it runs: `bin/link A cut | restore | slow 256 | drop-acks`.

Demo scenes: `live`, `offline`, `power_cut`, `lost_ack`, `conflict`,
`quarantine`, `void`, `tamper`, `reconcile`, `restore`, `measure`.

## Results (last full run, 14 Oct 2026, laptop under WSL)

**49 of 50 checks passed.** Every scene behaved as designed:

| Scene | What was shown |
|---|---|
| live | Patient + visit saved through the MaHIS API reached central in 1.3 s; each change is tagged with its endpoint, request id and user |
| offline | Work continued with the link cut; the queue drained in order when it came back, no gaps, each batch applied once |
| power_cut | Central died after applying a batch but before COMMIT: nothing half-applied, sequence unchanged; the resend applied it exactly once |
| lost_ack | Central committed but the answer was lost; the resend got central's stored answer and nothing was applied twice |
| conflict | Two offline sites edited different fields of one name: both edits survived on all three nodes. A birth date changed at both went to review |
| quarantine | A visit dated in the future was quarantined with its observations (same request) while other data kept flowing; fixing the date at the site released all three |
| void | Patient registered and voided while offline: central has it voided, with reason and user |
| tamper | The app's MySQL account cannot delete queued changes; a batch edited after sealing was refused with an alert |
| reconcile | Two rows corrupted behind the app's back were found by Merkle comparison (11 KB exchanged) and repaired with original ids |
| restore | Site B wiped and rebuilt from central in 12 s (1 001 rows): checksums verified, same local ids, new epoch; the old server stays locked out |

| Measurement | Value |
|---|---|
| Bytes per change, gzip (as sent) | 118 B (1 321 B uncompressed) |
| Changes per minute a 256 kbit/s link carries at the 50% cap | ~8 000 |
| Rollout snapshot, 2 sites × ~1 000 rows | 91 s |
| Capture overhead, visit + 20 obs (committed) | **not settled**: 10% to 88% between runs |

The one failed check is the capture-overhead target. Disk timing under WSL
varies too much (the same configuration ranged from 44 ms to 301 ms per save),
so the 10% target has to be measured on a real site server with
`rake site_sync:benchmark` (stop the agent first). Removing the in-trigger
hash or the extra log indexes made no difference beyond that noise.

## Known limits of the prototype

- **One lock at central.** Batches from all sites are applied one at a time so
  the downstream feed stays in commit order. A large catch-up from one site
  delays the others (seen during the rollout snapshot); production should use a
  committed-watermark instead.
- **Reference data is not synced.** Concepts, users and locations must be identical
  on every node. Concepts and locations match by id, users by uuid.
- **Out-of-scope columns** (`visit_id`, `order_id`, `form_id`, `value_group_id`)
  are kept in central's backup copy but not copied to other nodes.
- **HMAC signatures instead of mutual TLS**, and a demo API token instead of
  the login flow.
- **Hard deletes.** `site_sync:check` flags three hard deletes in
  `DuplicateIdentifierCleanupTask`. They are still captured (as tombstones) but
  should become voids.
- **Clock skew.** A site clock more than 5 minutes ahead is refused, but there is no
  tool yet to re-seal such batches after the clock is fixed.

## Where things are

| Piece | File |
|---|---|
| What is synced, ownership, lanes, protected fields | `config/site_sync_tables.yml` |
| Capture triggers (generated) | `lib/site_sync/trigger_generator.rb`, `rake site_sync:generate / install / check` |
| Request and job tagging | `ApplicationController#tag_sync_request`, `lib/site_sync/sidekiq_tagger.rb` |
| Seal + push, hash chain, acks | `app/services/site_sync/sender.rb` |
| Central validation, quarantine, field-level merge | `app/services/site_sync/central_ingest.rb` |
| Pull, on-demand patient fetch | `app/services/site_sync/puller.rb`, `downstream_applier.rb` |
| Merkle reconciliation | `lib/site_sync/merkle.rb`, `app/services/site_sync/reconciler.rb` |
| Restore | `app/services/site_sync/restore.rb`, `Api::V1::SiteSync::RestoreController` |
| Dashboard, heartbeat | `app/services/site_sync/dashboard.rb`, `heartbeat.rb` |
| Endpoints | `app/controllers/api/v1/site_sync/`, routes under `/api/v1/site_sync` |
| Agent loop | `rake site_sync:agent` (or the Sidekiq jobs in `app/jobs/site_sync/`) |

Sync is off unless `MAHIS_SYNC_ROLE` is set, so existing deployments are unaffected.
