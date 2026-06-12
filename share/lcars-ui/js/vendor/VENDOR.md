# Vendored JavaScript Libraries

**Location:** `lcars-ui/js/vendor/`
**Mirrored to homebrew-tap** — `sync-tap.sh` mirrors the whole `lcars-ui/` tree, so this doc is copied to `homebrew-tap/share/lcars-ui/js/vendor/VENDOR.md`. The `sync-tap-drift` CI gate enforces that the two copies stay identical; edit the canonical copy here and re-sync.
**Audit finding:** F-07-006 (XACA-0338)

---

## Libraries

### cytoscape.min.js

| Field | Value |
|-------|-------|
| Library | Cytoscape.js — graph theory / network visualization library |
| Version | 3.30.4 |
| Source URL | https://unpkg.com/cytoscape@3.30.4/dist/cytoscape.min.js |
| License | MIT (Copyright (c) 2016-2024, The Cytoscape Consortium) |
| SHA-256 | `1bb5340e549511e111b31e5684872c949ad33d40ea5dba0ad8e7d90c62c7b3b9` |
| File size | 373734 bytes |
| Locations | `lcars-ui/js/vendor/cytoscape.min.js` |

Version determined by: the minified bundle exports `c.version="3.30.4"` as a runtime property on the module's default export.

---

### chart.umd.min.js

| Field | Value |
|-------|-------|
| Library | Chart.js — HTML5 charts via `<canvas>` |
| Version | 4.5.1 |
| Source URL | https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.min.js |
| License | MIT (Copyright (c) Chart.js contributors) |
| SHA-256 | `48444a82d4edcb5bec0f1965faacdde18d9c17db3063d042abada2f705c9f54a` |
| File size | 208522 bytes |
| Locations | `lcars-ui/js/vendor/chart.umd.min.js` (primary), `fleet-monitor/server/public/lcars/js/vendor/chart.umd.min.js` (mirror) |

Version determined by: file header comment `/*! Chart.js v4.5.1` on line 1.

**Dual-location note:** The two copies are byte-for-byte identical (confirmed via `diff` and matching SHA-256 digests). Any future update must update both locations simultaneously.

---

## How to Verify Digests

```bash
shasum -a 256 lcars-ui/js/vendor/cytoscape.min.js
shasum -a 256 lcars-ui/js/vendor/chart.umd.min.js
shasum -a 256 fleet-monitor/server/public/lcars/js/vendor/chart.umd.min.js
# Confirm chart copies are identical
diff lcars-ui/js/vendor/chart.umd.min.js fleet-monitor/server/public/lcars/js/vendor/chart.umd.min.js && echo "IDENTICAL"
```

---

## How to Re-vendor a Library

1. Download the pinned release from the source URL above.
2. Verify the SHA-256 digest against the value recorded here.
3. Replace the file(s) in all locations listed above.
4. Update this file: version, source URL, SHA-256, file size.
5. If updating chart.umd.min.js, update both copy locations.
6. Commit as part of the relevant kanban item with a CHANGELOG entry.

---

## Recommended: CI Digest-Drift Check

A future CI step should run `shasum -a 256` against each vendored file and compare to the digests recorded in this file, failing the build if they diverge. This would catch accidental in-place edits to binary blobs or silent overwrite during merges. The check should also assert that the two chart.umd.min.js copies remain identical.

Example gate (bash):

```bash
EXPECTED_CYTOSCAPE="1bb5340e549511e111b31e5684872c949ad33d40ea5dba0ad8e7d90c62c7b3b9"
EXPECTED_CHART="48444a82d4edcb5bec0f1965faacdde18d9c17db3063d042abada2f705c9f54a"

actual=$(shasum -a 256 lcars-ui/js/vendor/cytoscape.min.js | awk '{print $1}')
[ "$actual" = "$EXPECTED_CYTOSCAPE" ] || { echo "DIGEST MISMATCH: cytoscape.min.js"; exit 1; }

actual=$(shasum -a 256 lcars-ui/js/vendor/chart.umd.min.js | awk '{print $1}')
[ "$actual" = "$EXPECTED_CHART" ] || { echo "DIGEST MISMATCH: chart.umd.min.js (lcars-ui)"; exit 1; }

actual=$(shasum -a 256 fleet-monitor/server/public/lcars/js/vendor/chart.umd.min.js | awk '{print $1}')
[ "$actual" = "$EXPECTED_CHART" ] || { echo "DIGEST MISMATCH: chart.umd.min.js (fleet-monitor)"; exit 1; }

diff lcars-ui/js/vendor/chart.umd.min.js fleet-monitor/server/public/lcars/js/vendor/chart.umd.min.js \
  || { echo "DRIFT: chart.umd.min.js copies diverged"; exit 1; }
```
