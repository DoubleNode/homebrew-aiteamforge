# Design: `--refresh-profiles` Merge Semantics

**XACA-0156-001 — Spec for subitem 002 (implementation)**

---

## Background

`aiteamforge-lcars.json` lives in `~/Library/Application Support/iTerm2/DynamicProfiles/`.
The installers (`install-kanban.sh`, `install-fleet-monitor.sh`) skip the file if it
already exists to avoid clobbering user customizations. Side effect: bug fixes shipped
in source (e.g., missing `Mouse Reporting`, corrected `Dynamic Profile Parent Name`)
never propagate through `brew upgrade`.

The `--refresh-profiles` flag does a per-Guid key-level merge: pull
AITeamForge-owned keys from the source file, leave user-owned keys alone.

---

## File Structure

The file is a single JSON object with a `Profiles` array. Each element is an iTerm2
Dynamic Profile dict identified by `Guid`. Merge happens **per-Guid**, not globally.

```json
{ "Profiles": [ { "Guid": "...", "Name": "...", ... }, ... ] }
```

Known profiles (as of v0.8.27):

| Guid | Name |
|------|------|
| `AITEAMFORGE-LCARS-WEB-0001-000000000001` | LCARS Web |
| `AITEAMFORGE-AGENT-PANEL-0001-000000000001` | Agent Panel |
| `AITEAMFORGE-DEFAULT-PROF-0001-000000000001` | Default |

Note: the source `aiteamforge-lcars.json` (shipped in the tap) currently only contains
LCARS Web and Agent Panel. The Default profile is written by `create-lcars-profile.py`
at setup time. The merge logic must handle whichever profiles are present in the source.

---

## Key Inventory

### 1. AITeamForge-Owned Keys (refresh on upgrade)

These keys control functionality we ship and maintain. Wrong values break features.
We own them and must be able to fix them without user action.

| Key | Profiles | Reason |
|-----|----------|--------|
| `Name` | All | Profile identity; iTerm2 looks up profiles by name |
| `Guid` | All | Immutable identity anchor; never changes |
| `Tags` | All | We set `["aiteamforge"]` for visibility/filtering |
| `Custom Command` | LCARS Web | Must be `"Browser"` for inline browser mode |
| `Mouse Reporting` | LCARS Web, Agent Panel | v0.8.27 bug fix — must be `true` for click-to-navigate in browser tab |
| `Dynamic Profile Parent Name` | All | Links to the correct parent for font/color inheritance; wrong value breaks the inheritance chain |
| `Background Color` | LCARS Web | Pure black (`0,0,0`) is required for the LCARS aesthetic; this is a functional requirement, not a personal preference |

**Rationale for `Background Color` as owned:** The LCARS Web profile is a browser
window. The background color is never visible to the user (the browser renders on top
of it). Its presence in the file is vestigial and cosmetic. Treating it as
AITeamForge-owned avoids confusion while causing no visible impact to the user.

**Rationale for `Dynamic Profile Parent Name` as owned:** This key links a profile to
its parent for settings inheritance. An incorrect or missing parent name silently breaks
font/color inheritance for all team members. The live file on test machines shows this
key present with value `"Default"` — but the source `aiteamforge-lcars.json` does not
include it. That gap is a pre-existing source omission, not a user customization. We
should own this key so we can add/correct it on upgrade.

---

### 2. User-Owned Keys (preserve on upgrade)

These keys represent personal preferences the user may have changed intentionally.
Overwriting them is a support incident waiting to happen.

| Key | Profiles | Reason |
|-----|----------|--------|
| `Normal Font` | Agent Panel, Default | User may have changed to their preferred font (observed in the wild: `JetBrainsMonoNF-Light 9` replacing our default `FiraCodeNFM-Light 8`) |
| `Non Ascii Font` | Any | User preference |
| `Foreground Color` | Any | Color scheme customization |
| `Transparency` | Any | Visual preference |
| `Blur` | Any | Visual preference |
| `Blur Radius` | Any | Visual preference |
| `Window Type` | Any | Windowing preference |
| `Columns` | Any | Terminal width preference |
| `Rows` | Any | Terminal height preference |
| `Scrollback Lines` | Any | Buffer size preference |
| `Unlimited Scrollback` | Any | Buffer preference |
| `Key Mappings` | Any | Custom keybindings |
| `Triggers` | Any | Custom triggers |
| `Initial Text` | Any | User-set startup text |
| `Custom Directory` | Any | Working directory preference |
| `Badge Text` | Any | Badge customization |
| `Semantic History` | Any | Click-to-open preference |
| `Smart Selection Rules` | Any | User-defined selection rules |
| `Session Close Action` | Any | Behavior on close |

**Rationale:** All of these represent visible, intentional user choices. The most
concrete real-world case observed: a user changed `Normal Font` in Agent Panel from
`FiraCodeNFM-Light 8` to `JetBrainsMonoNF-Light 9`. That change must survive upgrade.

---

### 3. Ambiguous Keys and Decisions

| Key | Profiles | Decision | Rationale |
|-----|----------|----------|-----------|
| `Initial URL` | LCARS Web | **AITeamForge-owned (source), but runtime-volatile** | The source sets a placeholder URL. `set-lcars-profile-browser.py` overwrites it at team startup with the correct per-team port. `--refresh-profiles` should restore the source placeholder, which will be corrected the next time the team starts. Do NOT treat the live URL as a user value. |
| `Color Space` (inside color objects) | All | **AITeamForge-owned** | This is a sub-field of color objects we own (e.g., `Background Color`). The color space is a technical attribute we control. |
| `Use Non-ASCII Font` | Any | **User-owned** | Enables/disables the non-ASCII font. Follows `Non Ascii Font`. |
| `ASCII Anti Aliased` | Any | **User-owned** | Rendering preference. |
| `Ambiguous Double Width` | Any | **User-owned** | Unicode width preference. |
| `Use Bold Font` | Any | **User-owned** | Rendering preference. |
| `Use Italic Font` | Any | **User-owned** | Rendering preference. |
| `Horizontal Spacing` | Any | **User-owned** | Font spacing preference. |
| `Vertical Spacing` | Any | **User-owned** | Font spacing preference. |

---

## Profile-Level Rules

### New Profile Rule (profile in source, not in live file)

**Decision: Add the profile as-is from source.**

Rationale: A new Guid means a new feature we're shipping. The user has no
customizations for something they've never seen. Adding it is safe and necessary for
the feature to work.

### Removed Profile Rule (profile in live file, not in source)

**Decision: Keep the live profile unchanged.**

Rationale: The user may have created custom profiles under our file (unlikely but
possible), or an earlier installer version wrote a profile we later removed. In either
case, deleting it silently would be destructive. The worst outcome of keeping it is a
stale, harmless profile entry.

---

## Merge Algorithm (pseudocode for subitem 002)

```
function merge_profiles(source_file, live_file):
    source = parse_json(source_file)
    live = parse_json(live_file)

    # Index live profiles by Guid
    live_by_guid = { p["Guid"]: p for p in live["Profiles"] }

    result_profiles = list(live["Profiles"])  # start with all live profiles

    for src_profile in source["Profiles"]:
        guid = src_profile["Guid"]

        if guid not in live_by_guid:
            # New profile rule: add as-is
            result_profiles.append(src_profile)
        else:
            live_profile = live_by_guid[guid]
            # Key-level merge: source wins for owned keys, live wins for user keys
            for key, value in src_profile.items():
                if key in AITF_OWNED_KEYS:
                    live_profile[key] = value
                # else: leave live value untouched

    live["Profiles"] = result_profiles
    write_json(live_file, live)
```

AITF_OWNED_KEYS = {
  "Name", "Guid", "Tags", "Custom Command", "Mouse Reporting",
  "Dynamic Profile Parent Name", "Background Color", "Initial URL"
}

---

## Keys Not Yet in Source That Should Be Added

The source `aiteamforge-lcars.json` currently omits `Dynamic Profile Parent Name`. This
key is present in live files written by `create-lcars-profile.py` (which sets it to
`"Default"`), but the static source JSON does not include it.

**Recommendation for subitem 002:** Add `"Dynamic Profile Parent Name": "Default"` to
both profiles in the source JSON as part of this work. This ensures `--refresh-profiles`
can propagate it correctly to installs that have the wrong or missing parent.

---

## What `--refresh-profiles` Does NOT Do

- Does not touch any key not present in the source file (unknown keys in live are left alone)
- Does not delete profiles absent from source
- Does not modify iTerm2's plist (`com.googlecode.iterm2.plist`)
- Does not restart iTerm2 (iTerm2 hot-reloads DynamicProfiles automatically)
- Does not run as part of a standard `brew upgrade` — user must pass the flag explicitly

---

## Summary Table

| Category | Action |
|----------|--------|
| AITeamForge-owned key in both source and live | Overwrite live with source value |
| AITeamForge-owned key in source, missing from live | Add to live profile |
| User-owned key in live | Leave untouched |
| Ambiguous key (see table above) | Follow per-key decision |
| Profile Guid in source, not in live | Add profile as-is from source |
| Profile Guid in live, not in source | Keep live profile unchanged |
| Unknown key in live (not in either table) | Leave untouched (safe default) |
