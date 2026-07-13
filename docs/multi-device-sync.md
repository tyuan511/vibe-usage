# Multi-Device Sync

VibeUsage can optionally synchronize aggregate usage through a user-provided
WebDAV or S3-compatible object store. Sync is disabled by default and does not
require a VibeUsage account or a VibeUsage-operated server.

## Scope

Each installation owns a stable device ID and publishes only its own aggregate
usage. Remote payloads contain UTC hour, agent, model family, token counts,
cost, event count, and estimated-cost count. They do not contain source log
lines, file paths, projects, sessions, request IDs, quota credentials, or OAuth
tokens.

Sync is a cross-device reporting replica, not a backup of raw usage events.
Deleting or rebuilding the local database creates a new installation identity;
aggregate remote documents cannot restore the original event database.

## Remote Layout

All providers expose the same object-key interface and use this namespace:

```text
<configured base>/vibeusage/sync/v1/
  devices/<device-id>/
    profile.json
    index.json
    days/<yyyy-MM-dd>.json
```

Day documents contain UTC hourly buckets. A device uploads changed day
documents before publishing its updated index. Readers verify each day's
SHA-256 checksum from the index before replacing their local remote cache.

Each device writes only its own directory. If the same agent log is copied to
two Macs, both installations count it independently; cross-device event
deduplication is intentionally not attempted.

## Providers

`SyncObjectStore` is the provider seam. The sync engine only uses access
validation, list, read, write, and delete operations. Provider adapters own
authentication, request signing, paths, and response parsing.

- WebDAV uses HTTPS Basic authentication and the standard `MKCOL`, `PROPFIND`,
  `PUT`, `GET`, and `DELETE` methods.
- S3 supports configurable HTTPS endpoints, regions, buckets, prefixes,
  path-style or virtual-hosted addressing, and AWS Signature Version 4.
- S3 temporary STS session tokens, WebDAV OAuth, client certificates, and TLS
  validation bypasses are not supported.

Non-secret connection configuration is stored in UserDefaults. WebDAV
passwords and S3 secret keys are stored in the macOS Keychain. Saving a target
first performs a write/read/delete probe. Changing targets marks all local
history for publication at the new location; data is not copied from the old
provider.

## Scheduling and Visibility

The app pulls on startup and synchronizes every 15 minutes. Automatic local
ingestion updates only the local database; it does not trigger a network sync.
Manual refresh scans local logs before synchronizing, and committing a local
device-name change triggers one immediate sync. Failures retain cached remote
data and retry with backoff without blocking local ingestion.

All discovered devices are visible by default. Device visibility is a local UI
preference that consistently affects the menu-bar total, heatmap, agent/model
breakdowns, and device list. Disabling network sync keeps cached remote history
visible; removing the local sync configuration explicitly clears that cache
without deleting remote objects.
