---
name: team-mission-status
description: Generates a status of all missions for the current team and adds them to the LCARS Mission Queue. Detects team automatically from terminal context. Supports all teams (iOS, Android, Firebase, Academy, Command, DNS, Freelance, cross-platform coordination). Includes coordination missions between multiple teams. Supports hierarchical subitems with collapsible UI and automatic intelligent expansion of complex missions into subitems. Supports due dates with urgency indicators and clickable tag pills.
version: 1.8.0
author: Captain Nahla Ake (Starfleet Academy Chancellor)
company: Starfleet Academy - AI Team Development
project: Dev Team LCARS Infrastructure
terminals:
  - All terminals (auto-detects team)
supported_os:
  - macOS
  - Linux
dependencies:
  - Claude Code
  - Kanban board system
tags:
  - mission-queue
  - lcars
  - team-status
  - kanban
  - backlog
  - jira
  - subitems
  - auto-expansion
  - tags
command_shortcut: kb-backlog
last_updated: 2026-01-07
status: production-ready
model: sonnet
---

# Team Mission Status Generator

## Skill Metadata

**Name:** Team Mission Status Generator
**Version:** 1.8.0
**Author:** Captain Nahla Ake (Starfleet Academy)
**Command Shortcut:** `kb-backlog`
**Platforms:** All team platforms
**Last Updated:** January 7, 2026

---

## Purpose

This skill generates a comprehensive status of all missions for the **current team only** and adds them to that team's LCARS Mission Queue (kanban backlog). It automatically detects which team is active based on terminal context and gathers missions from multiple sources. **New in v1.8.0:** Missions now support clickable tag pills for categorization and filtering.

**Key Principles:**
- **Team-Specific Focus:** Only gathers missions relevant to the current team
- **Cross-Team Coordination:** MAY include coordination missions that span multiple teams (e.g., iOS + Android + Firebase working together)
- **Universal Compatibility:** Works with ALL teams in the team infrastructure
- **LCARS Integration:** Updates the team's kanban board `backlog` array
- **Intelligent Expansion:** Automatically breaks down complex missions into trackable subitems based on category, keywords, and description content

---

## Team Detection

### Automatic Detection Methods

The skill detects the current team using these methods (in priority order):

**1. Terminal/Session Name Prefix**
```
ios-*                              -> iOS Team (TNG)
android-*                          -> Android Team (TOS)
firebase-*                         -> Firebase Team (DS9)
academy-*                          -> Academy Team (DSC)
command-*                          -> Command Team (DSC)
dns-*                              -> DNS Framework Team (Lower Decks)
freelance-{group}-{project}-*      -> Freelance Project Team (ENT)
<coordination>-*                    -> Cross-platform coordination team, if the fleet has one (VOY)
```

**Special Handling for Freelance Teams:**
Freelance session names include group and project: `freelance-<group>-<project>-command`
- Extract team as: `freelance-<group>-<project>`
- Maps to board: `freelance-<group>-<project>-board.json`
- Each freelance project has its own isolated backlog

**2. Environment Variable**
```bash
echo $LCARS_TEAM
# Returns: ios, android, firebase, academy, command, dns, freelance, or a coordination team name
```

**3. Current Working Directory**
```
<ios-repo>/...      -> iOS   (matched via $IOS_REPO path or terminal-name heuristic)
<android-repo>/...  -> Android
<firebase-repo>/... -> Firebase
<academy-repo>/... -> Academy (default)
```

**4. Kanban Board Context**
Read from `lcars-target.js` or session port files.

### Team Configuration Map

| Team | Kanban Board | Primary Focus |
|------|--------------|---------------|
| **iOS** | `ios-board.json` | iOS App |
| **Android** | `android-board.json` | Android App |
| **Firebase** | `firebase-board.json` | Firebase Functions/Rules |
| **Academy** | `academy-board.json` | Dev Team Infrastructure |
| **Command** | `command-board.json` | Strategic Operations |
| **DNS** | `dns-board.json` | DNS Framework Packages |
| **Freelance** | `freelance-{group}-{project}-board.json` | Per-project isolation |
| **Coordination** | (uses ios/android/firebase) | Cross-platform coordination, if the fleet has such a team |

**Freelance Board Examples:**
- `freelance-<group>-<project-a>-board.json` - first project
- `freelance-<group>-<project-b>-board.json` - second project

---

## Command Patterns

### Primary Command

**Command:** `kb-backlog` or `"Generate mission status for this team"`

**Aliases:**
- `kb-backlog`
- `"Update LCARS mission queue"`
- `"Generate team mission status"`
- `"Refresh mission backlog"`
- `"Show team missions and add to queue"`

### Examples

**Basic Usage (auto-detect team):**
```
kb-backlog
```
Result: Detects current team, gathers missions, updates that team's backlog.

**With Explicit Team:**
```
kb-backlog ios
kb-backlog android
kb-backlog firebase
```

**Include Cross-Team Coordination:**
```
kb-backlog --with-coordination
```
Result: Also includes missions that coordinate with other teams.

**Expand/Unexpand Missions:**
```
kb-backlog expand 0              # Auto-expand mission at index 0
kb-backlog expand 0 release      # Expand using release template
kb-backlog unexpand 0            # Remove subitems from mission 0
```

### Adding Missions with Options

**Basic add:**
```bash
kb-backlog add "Task title" high
```

**Add with description (3rd parameter):**
```bash
kb-backlog add "Task title" high "Detailed description here"
```

**Add with JIRA ID (4th parameter):**
```bash
kb-backlog add "Fix login crash" critical "" PROJ-123
kb-backlog add "API integration" high "Waiting for backend" PROJ-456
```

**Add with due date (6th parameter):**
```bash
kb-backlog add "Sprint goal" high "" "" "" 2026-01-15
kb-backlog add "Release v2.0" critical "" PROJ-789 "" +2w
kb-backlog add "Doc update" medium "Update API docs" "" "" tomorrow
```

**Using priority shortcuts:**
```bash
kb-backlog add "Production crash" crit "" PROJ-789     # critical
kb-backlog add "Normal task" med                      # medium
kb-backlog add "Waiting on design" block              # blocked
```

**Multi-line description example:**
```bash
kb-backlog add "Refactor auth module" high "Need to:
- Extract token validation
- Add refresh token support
- Update error handling"
```

**Control automatic expansion:**
```bash
kb-backlog add "Complex feature" high "" "" --expand      # Force expansion
kb-backlog add "Simple fix" high "" "" --no-expand        # Prevent expansion
```

**Add with effort estimate (developer-hours for a normal human developer):**
```bash
kb-backlog add "Refactor auth module" high "" "" --points 4
kb-backlog add "Quick config fix" low "" "" --points 0.5
```

> **Start gate:** every mission must have a developer-hours estimate before it can be started (`kb-pick`/`kb-run`). Estimation is optional at creation — supply `--points <hours>` here when known, or set it later with `kb-backlog points <id> <hours>`. Run `kb-backlog unestimated` to surface all open missions that are still unestimated.

### Managing JIRA IDs

**View JIRA ID:**
```bash
kb-backlog jira 0                    # View JIRA ID for item at index 0
```

**Set JIRA ID:**
```bash
kb-backlog jira 0 PROJ-123             # Set JIRA ID for item at index 0
```

**Clear JIRA ID:**
```bash
kb-backlog jira 0 -                  # Clear JIRA ID (use hyphen)
```

### Managing GitHub Issues

For teams without JIRA integration (Academy, DNS, Freelance), use GitHub issues instead.

**Shorthand format (uses team default repo):**
```bash
kb-backlog github 0 #42              # Links to team's default repo
kb-backlog gh 0 123                  # Alias, # is optional
```

**Full format (explicit repo):**
```bash
kb-backlog github 0 anthropics/claude-code#99
kb-backlog github 0 <org>/<repo>#42
```

**Team default repos:**
| Team | Default Repo |
|------|--------------|
| Academy | `<org>/<academy-repo>` |
| DNS | `<org>/<dns-repo>` |
| Freelance | `<org>/<project-repo>` |

**Clear GitHub issue:**
```bash
kb-backlog github 0 -                # Clear GitHub issue (use hyphen)
```

### Managing Subitems

Break down missions into smaller subitems that can be individually tracked, have their own JIRA/GitHub links, and be promoted to active work.

**Add subitem to a mission:**
```bash
kb-backlog sub add 0 "Subitem title"              # Add subitem to mission at index 0
kb-backlog sub add 0 "API integration" PROJ-456     # Add subitem with JIRA ID
```

**List subitems:**
```bash
kb-backlog sub list 0                # List all subitems for mission at index 0
```

**Remove subitem:**
```bash
kb-backlog sub remove 0 1            # Remove subitem 1 from mission 0
```

**Mark subitem complete/incomplete:**
```bash
kb-backlog sub done 0 1              # Mark subitem 1 as completed
kb-backlog sub todo 0 1              # Mark subitem 1 as todo (incomplete)
```

**Set subitem JIRA ID:**
```bash
kb-backlog sub jira 0 1 PROJ-789       # Set JIRA ID for subitem [0.1]
```

**Set subitem GitHub issue:**
```bash
kb-backlog sub github 0 1 #42        # Set GitHub issue for subitem [0.1]
```

**Start subitem (promote to active work):**
```bash
kb-backlog sub start 0 1             # Start subitem 1 from mission 0
```
This creates an activeWindow entry with the subitem task and marks it `in_progress`.

---

## Automatic Subitem Expansion (v1.6.0)

The skill now intelligently expands complex missions into subitems when appropriate. This reduces manual breakdown work and ensures comprehensive task tracking.

### Expansion Triggers

Missions are automatically expanded when **any** of these conditions are met:

#### 1. Category-Based Expansion

Certain categories typically require multi-step work:

| Category | Auto-Expand | Typical Subitems |
|----------|-------------|------------------|
| `feature` | ✅ Yes | Design, Implementation, Testing, Documentation |
| `epic` | ✅ Yes | Stories derived from epic scope |
| `release` | ✅ Yes | Build, QA, Deploy, Verify, Announce |
| `refactor` | ✅ Yes | Analysis, Implementation, Testing, Cleanup |
| `bugfix` | ⚠️ Conditional | Only if description suggests multiple causes |
| `documentation` | ❌ No | Usually atomic |
| `technical` | ⚠️ Conditional | Based on scope indicators |

#### 2. Complexity Indicators in Title/Description

**Keyword Triggers:**
```
"epic"          → Expand into story-level subitems
"integration"   → API, Client, Testing subitems
"migration"     → Backup, Migrate, Verify, Cleanup subitems
"rollout"       → Build, Stage, Deploy, Verify subitems
"redesign"      → Design, Implement, Test, Deploy subitems
"refactor"      → Analyze, Implement, Test, Document subitems
```

**Conjunction Detection:**
```
"and" / "&"     → Split into separate subitems
"then"          → Sequential subitems
"including"     → Nested subitems
"with"          → Bundled subitems
```

**List Detection:**
```
- Bullet points in description
- Numbered lists (1. 2. 3.)
- Semicolon-separated items
- Comma-separated technical items
```

#### 3. Cross-Team Coordination

Missions with `coordination` array automatically get platform-specific subitems:

```json
{
  "title": "Cross-Platform Feature",
  "coordination": ["ios", "android", "firebase"],
  "subitems": [
    {"title": "iOS Implementation", "status": "todo"},
    {"title": "Android Implementation", "status": "todo"},
    {"title": "Firebase Backend", "status": "todo"},
    {"title": "Cross-Platform Testing", "status": "todo"}
  ]
}
```

#### 4. Priority-Based Expansion

| Priority | Expansion Behavior |
|----------|-------------------|
| `critical` | **Always expand** - Critical items need clear breakdown |
| `high` | Expand if complexity detected |
| `medium` | Expand if category suggests it |
| `low` | Expand only if explicitly complex |
| `blocked` | **Never expand** - Waiting on external factors |

### Expansion Templates

#### Feature Template
```json
{
  "subitems": [
    {"title": "Requirements/Design", "status": "todo"},
    {"title": "Implementation", "status": "todo"},
    {"title": "Unit Tests", "status": "todo"},
    {"title": "Integration Testing", "status": "todo"},
    {"title": "Documentation", "status": "todo"}
  ]
}
```

#### Release Template
```json
{
  "subitems": [
    {"title": "Build Preparation", "status": "todo"},
    {"title": "QA Validation", "status": "todo"},
    {"title": "Release Notes", "status": "todo"},
    {"title": "Deploy to Store", "status": "todo"},
    {"title": "Post-Release Verification", "status": "todo"}
  ]
}
```

#### Refactor Template
```json
{
  "subitems": [
    {"title": "Code Analysis", "status": "todo"},
    {"title": "Design New Structure", "status": "todo"},
    {"title": "Implement Changes", "status": "todo"},
    {"title": "Update Tests", "status": "todo"},
    {"title": "Code Review", "status": "todo"}
  ]
}
```

#### Migration Template
```json
{
  "subitems": [
    {"title": "Backup Current State", "status": "todo"},
    {"title": "Prepare Migration Scripts", "status": "todo"},
    {"title": "Execute Migration", "status": "todo"},
    {"title": "Verify Data Integrity", "status": "todo"},
    {"title": "Cleanup Legacy Code", "status": "todo"}
  ]
}
```

#### Bug Investigation Template
```json
{
  "subitems": [
    {"title": "Reproduce Issue", "status": "todo"},
    {"title": "Root Cause Analysis", "status": "todo"},
    {"title": "Implement Fix", "status": "todo"},
    {"title": "Regression Testing", "status": "todo"}
  ]
}
```

### When NOT to Expand

Expansion is **skipped** when:

1. **Already has subitems** - Don't overwrite existing breakdown
2. **Status is `blocked`** - Waiting items aren't actionable
3. **Category is atomic** - `documentation`, simple `technical` tasks
4. **Title contains "quick"**, "simple", "minor", "small"
5. **Description indicates single action** - No lists, no conjunctions
6. **Explicit `noExpand: true` flag** - User override

### Controlling Expansion Behavior

**Add with no expansion:**
```bash
kb-backlog add "Simple fix" high "" "" --no-expand
```

**Force expansion on atomic item:**
```bash
kb-backlog add "Complex bug" high "" "" --expand
```

**Expand existing item:**
```bash
kb-backlog expand 0                  # Auto-expand mission at index 0
kb-backlog expand 0 feature          # Use specific template
```

**Collapse/remove auto-generated subitems:**
```bash
kb-backlog unexpand 0                # Remove all subitems from mission 0
```

### Expansion Processing Logic

```python
def should_expand_mission(mission):
    """Determine if mission warrants automatic subitem expansion."""

    # Never expand if already has subitems
    if mission.get('subitems') and len(mission['subitems']) > 0:
        return False

    # Never expand blocked items
    if mission.get('priority') == 'blocked' or mission.get('status') == 'blocked':
        return False

    # Check for explicit flags
    if mission.get('noExpand'):
        return False

    # Always expand critical items
    if mission.get('priority') == 'critical':
        return True

    # Category-based expansion
    expandable_categories = ['feature', 'epic', 'release', 'refactor']
    if mission.get('category') in expandable_categories:
        return True

    # Cross-team coordination always expands
    if mission.get('coordination') and len(mission['coordination']) > 1:
        return True

    # Check complexity indicators in title/description
    complexity_keywords = ['epic', 'integration', 'migration', 'rollout',
                          'redesign', 'refactor', 'overhaul', 'complete']
    text = f"{mission.get('title', '')} {mission.get('description', '')}".lower()

    for keyword in complexity_keywords:
        if keyword in text:
            return True

    # Check for list patterns in description
    desc = mission.get('description', '')
    if any(pattern in desc for pattern in ['- ', '1.', '2.', '; ', ' and ', ' & ']):
        return True

    # Check for simplicity indicators (don't expand)
    simple_keywords = ['quick', 'simple', 'minor', 'small', 'trivial', 'hotfix']
    for keyword in simple_keywords:
        if keyword in text:
            return False

    return False

def generate_subitems(mission):
    """Generate appropriate subitems based on mission characteristics."""

    category = mission.get('category', 'feature')
    coordination = mission.get('coordination', [])
    description = mission.get('description', '')

    subitems = []

    # Cross-team coordination: generate platform subitems
    if len(coordination) > 1:
        platform_names = {
            'ios': 'iOS Implementation',
            'android': 'Android Implementation',
            'firebase': 'Firebase Backend',
            'academy': 'Infrastructure Updates',
            'command': 'Strategic Coordination',
            'dns': 'Framework Updates',
            'freelance': 'Client Deliverables'
        }
        for team in coordination:
            subitems.append({
                'title': platform_names.get(team, f'{team.capitalize()} Work'),
                'status': 'todo'
            })
        subitems.append({'title': 'Cross-Platform Testing', 'status': 'todo'})
        return subitems

    # Parse description for explicit list items
    if description:
        list_items = extract_list_items(description)
        if list_items:
            return [{'title': item, 'status': 'todo'} for item in list_items]

    # Use category templates
    templates = {
        'feature': ['Requirements/Design', 'Implementation', 'Unit Tests',
                   'Integration Testing', 'Documentation'],
        'epic': ['Story Breakdown', 'Sprint Planning', 'Implementation',
                'QA Validation', 'Release'],
        'release': ['Build Preparation', 'QA Validation', 'Release Notes',
                   'Deploy to Store', 'Post-Release Verification'],
        'refactor': ['Code Analysis', 'Design New Structure', 'Implement Changes',
                    'Update Tests', 'Code Review'],
        'bugfix': ['Reproduce Issue', 'Root Cause Analysis', 'Implement Fix',
                  'Regression Testing']
    }

    template_items = templates.get(category, templates['feature'])
    return [{'title': item, 'status': 'todo'} for item in template_items]

def extract_list_items(description):
    """Extract list items from description text."""
    items = []

    # Bullet points
    for line in description.split('\n'):
        line = line.strip()
        if line.startswith('- ') or line.startswith('* '):
            items.append(line[2:].strip())
        elif line and line[0].isdigit() and '. ' in line:
            items.append(line.split('. ', 1)[1].strip())

    # Semicolon-separated (if no bullets found)
    if not items and '; ' in description:
        items = [item.strip() for item in description.split('; ')]

    return items
```

### Example: Automatic Expansion in Action

**Input Mission:**
```json
{
  "title": "Package Purchase Integration",
  "priority": "high",
  "category": "feature",
  "description": "Enable package purchases including:\n- API integration\n- UI implementation\n- Payment flow\n- Error handling",
  "coordination": ["ios", "android", "firebase"]
}
```

**Output After Expansion:**
```json
{
  "title": "Package Purchase Integration",
  "priority": "high",
  "category": "feature",
  "description": "Enable package purchases including:\n- API integration\n- UI implementation\n- Payment flow\n- Error handling",
  "coordination": ["ios", "android", "firebase"],
  "collapsed": true,
  "subitems": [
    {"id": "IOS-001-0", "title": "iOS Implementation", "status": "todo"},
    {"id": "IOS-001-1", "title": "Android Implementation", "status": "todo"},
    {"id": "IOS-001-2", "title": "Firebase Backend", "status": "todo"},
    {"id": "IOS-001-3", "title": "Cross-Platform Testing", "status": "todo"}
  ]
}
```

**Alternative (using description list):**
```json
{
  "subitems": [
    {"id": "IOS-001-0", "title": "API integration", "status": "todo"},
    {"id": "IOS-001-1", "title": "UI implementation", "status": "todo"},
    {"id": "IOS-001-2", "title": "Payment flow", "status": "todo"},
    {"id": "IOS-001-3", "title": "Error handling", "status": "todo"}
  ]
}
```

### Toggle Mission Expansion

Control collapsed/expanded state for missions with subitems:

```bash
kb-backlog toggle 0                  # Toggle collapsed state for mission at index 0
```

The collapsed state persists in the JSON file and is remembered across LCARS refreshes.

### Managing Descriptions

**View existing description:**
```bash
kb-backlog desc 0                    # View description for item at index 0
```

**Set/update description:**
```bash
kb-backlog desc 0 "New description"  # Set description for item at index 0
```

**Multi-line description:**
```bash
kb-backlog desc 0 "This is a multi-line
description that will display
under the mission title"
```

**Clear description:**
```bash
kb-backlog desc 0 -                  # Clear description (use hyphen)
```

### Managing Due Dates

Set target completion dates for missions. Due dates trigger visual urgency indicators in the LCARS UI.

**View existing due date:**
```bash
kb-backlog due 0                     # View due date for item at index 0
```

**Set due date:**
```bash
kb-backlog due 0 2026-01-15          # Set due date (ISO 8601 format: YYYY-MM-DD)
kb-backlog due 0 tomorrow            # Natural language: tomorrow
kb-backlog due 0 "next friday"       # Natural language: next Friday
kb-backlog due 0 +7d                 # Relative: 7 days from now
kb-backlog due 0 +2w                 # Relative: 2 weeks from now
```

**Clear due date:**
```bash
kb-backlog due 0 -                   # Clear due date (use hyphen)
```

**Due Date Display in LCARS UI:**

| Time Until Due | Indicator | Color |
|----------------|-----------|-------|
| Overdue | `OVERDUE` badge (pulsing) | Red |
| Due today | `TODAY` badge | Orange |
| Due within 3 days | `SOON` badge | Yellow |
| Due within 7 days | Date shown | Normal |
| Due later | Date shown (dimmed) | Gray |

**Priority Boost for Due Dates:**

Due dates can automatically influence sort order within the same priority level:
- Overdue items sort to the top of their priority group
- Items due today sort before items due later
- Items without due dates sort after items with due dates (within same priority)

**Adding Mission with Due Date:**
```bash
kb-backlog add "Complete API docs" high "" "" "" 2026-01-20
kb-backlog add "Release prep" critical "" PROJ-123 "" +5d
```

The 6th parameter is the due date (after priority, description, JIRA ID, and expand flag).

### Managing Tags

Tags are displayed as clickable pill buttons in the LCARS UI. When clicked, they automatically filter the mission queue to show items with matching tags.

**View current tags:**
```bash
kb-backlog tag 0                      # Show tags for item at index 0
```

**Set tags (replaces existing):**
```bash
kb-backlog tag 0 iOS feature urgent   # Set multiple tags
kb-backlog tag 0 refactor             # Set single tag
```

**Add tags (preserves existing):**
```bash
kb-backlog tag 0 add testing          # Add one tag
kb-backlog tag 0 add iOS Android      # Add multiple tags
```

**Remove specific tags:**
```bash
kb-backlog tag 0 rm testing           # Remove one tag
kb-backlog tag 0 rm iOS Android       # Remove multiple tags
```

**Clear all tags:**
```bash
kb-backlog tag 0 clear                # Remove all tags
```

**Subitem tags:**
```bash
kb-backlog sub tag 0 1 iOS testing    # Set tags on subitem [0.1]
kb-backlog sub tag 0 1 add feature    # Add tag to subitem
kb-backlog sub tag 0 1 rm testing     # Remove tag from subitem
kb-backlog sub tag 0 1 clear          # Clear all subitem tags
```

**Tag Display in LCARS UI:**

| Feature | Behavior |
|---------|----------|
| Position | Far right, below the timestamp |
| Appearance | Purple pill with black vertical separators between tags |
| Click Action | Filters mission queue to show items with that tag |
| Text Display | Uppercase |

**Tag Use Cases:**

| Tag Type | Examples | Purpose |
|----------|----------|---------|
| Platform | `iOS`, `Android`, `Firebase` | Filter by platform |
| Category | `feature`, `bugfix`, `refactor` | Filter by work type |
| Priority | `urgent`, `blocked`, `waiting` | Custom priority flags |
| Sprint | `sprint-1`, `sprint-2` | Sprint organization |
| Component | `API`, `UI`, `database` | Technical component |

**Search Integration:**
- Text search includes tag content
- Searching for "iOS" finds items tagged with "iOS"
- Tags provide quick one-click filtering

---

## Mission Sources

### 1. Active Session Todos

Extract from the team's `activeWindows` in kanban board:
- `todoProgress.total` - Total todos in current session
- `todoProgress.completed` - Completed todos
- `task` field - Current task description

### 2. Existing Backlog Items

Read current `backlog` array from team's kanban board to avoid duplicates.

### 3. Session Status File

Read `SESSION_STATUS.md` from the team's project directory (skip it if the file is absent) for:
- Pending tasks
- Known issues
- Next steps

### 4. Git Status

Analyze modified files to infer in-progress work:
```bash
git status --porcelain
```

---

## Mission Priority Classification

### Priority Levels

| Priority | Indicator | Criteria | Sort Order |
|----------|-----------|----------|------------|
| **critical** | RED (pulsing) | Production crashes, P0 emergencies | 1st (top) |
| **high** | ORANGE | In Progress tasks, P1, urgent features | 2nd |
| **medium** | YELLOW | Planned features, P2, backlog items | 3rd |
| **low** | TAN | Nice-to-have, technical debt, P3 | 4th |
| **blocked** | GRAY (⏸) | Waiting on external dependency | 5th (bottom) |

**Sort Order:** Critical items appear first (most urgent), blocked items appear last (waiting on external factors).

### Priority Shortcuts

| Full | Shortcut |
|------|----------|
| `critical` | `crit` |
| `medium` | `med` |
| `blocked` | `block` |

### Status Types

| Status | Meaning |
|--------|---------|
| `in_progress` | Currently being worked on |
| `pending` | Ready to start, queued |
| `blocked` | Waiting on external dependency |
| `todo` | Not yet started |
| `ongoing` | Continuous task (monitoring, etc.) |
| `backlog` | Future consideration |

---

## Mission Object Format

Each mission in the backlog follows this structure:

```json
{
  "id": "IOS-001",
  "title": "Package Purchases",
  "priority": "high",
  "status": "in_progress",
  "category": "feature",
  "project": "MyApp-iOS",
  "description": "Enable package purchases in mobile app",
  "jiraId": "PROJ-123",
  "coordination": ["android", "firebase"],
  "addedAt": "2026-01-02T14:30:00Z",
  "dueDate": "2026-01-15",
  "collapsed": true,
  "tags": ["iOS", "feature", "payment"],
  "subitems": [
    {
      "id": "IOS-001-1",
      "title": "API Integration",
      "status": "completed",
      "jiraKey": "PROJ-124",
      "tags": ["API", "backend"]
    },
    {
      "id": "IOS-001-2",
      "title": "UI Implementation",
      "status": "in_progress",
      "jiraKey": "PROJ-125",
      "description": "Build card selection interface",
      "tags": ["UI", "SwiftUI"]
    },
    {
      "id": "IOS-001-3",
      "title": "Payment Flow Testing",
      "status": "todo",
      "githubIssue": "#42",
      "tags": ["testing", "payment"]
    }
  ]
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique identifier (team prefix + number) |
| `title` | Yes | Short mission title |
| `priority` | Yes | critical, high, medium, low, blocked |
| `status` | Yes | in_progress, pending, blocked, todo, ongoing, backlog |
| `addedAt` | Yes | ISO 8601 timestamp when mission was added (e.g., "2026-01-02T14:30:00Z") |
| `jiraId` | No | JIRA ticket ID (e.g., "PROJ-123", "PROJ-456") - displays as blue tappable link |
| `githubIssue` | No | GitHub issue (e.g., "#123" or "owner/repo#123") - displays as purple tappable link |
| `category` | No | feature, bugfix, release, testing, documentation, technical |
| `project` | No | Project/repository name |
| `description` | No | Longer description |
| `coordination` | No | Array of other teams involved |
| `collapsed` | No | Boolean - UI expansion state (default: true = collapsed) |
| `dueDate` | No | ISO 8601 date (e.g., "2026-01-15") - displays with visual urgency indicators |
| `tags` | No | Array of tag strings - displays as clickable pills, click to filter |
| `subitems` | No | Array of subitem objects (see below) |

### Subitem Object Format

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Auto | Auto-generated: `{parent-id}-{index}` (e.g., "IOS-001-1") |
| `title` | Yes | Short subitem title |
| `status` | Yes | todo, in_progress, completed |
| `jiraKey` | No | Subitem's own JIRA ticket (independent from parent) |
| `githubIssue` | No | Subitem's own GitHub issue (independent from parent) |
| `tags` | No | Array of tag strings - displays as clickable pills, click to filter |
| `description` | No | Optional longer description |

### LCARS UI Display

- Items with subitems show ▶/▼ expand indicator
- Collapsed by default (subitems hidden)
- Badge shows completion ratio (e.g., "2/5" = 2 of 5 complete)
- Expanded subitems render indented below parent
- Status indicators: ○ (todo), ● (in_progress), ✓ (completed)
- Tags display as purple pills with black vertical separators
- Click any tag to filter the mission queue

---

## Output Behavior

### 1. Console Output

Displays mission status in LCARS-style format:

```
╔══════════════════════════════════════════════════════════════╗
║  LCARS MISSION QUEUE - iOS TEAM (U.S.S. Enterprise NCC-1701-D)
╠══════════════════════════════════════════════════════════════╣
║
║  ▓▓▓ ACTIVE MISSIONS ▓▓▓
║
║  🔴 [IOS-001] Package Purchases
║     Priority: HIGH | Status: IN PROGRESS
║     Enable package purchases in mobile app
║
║  🟡 [IOS-002] Fix Infinite Spinner Bug
║     Priority: MEDIUM | Status: IN PROGRESS
║     Bug: Swipe down on Sign In causes infinite spinner
║
║  ▓▓▓ BLOCKED ▓▓▓
║
║  ⛔ [IOS-003] Activity Type A Support
║     Priority: HIGHEST | Status: BLOCKED
║     Awaiting backend API completion
║
║  ▓▓▓ QUEUED ▓▓▓
║
║  📋 [IOS-004] Activity Type B Support
║     Priority: HIGH | Status: TODO
║
║  ▓▓▓ COORDINATION MISSIONS ▓▓▓
║
║  🔗 [COORD-001] Cross-Platform Rollout Epic
║     Platforms: iOS, Android, Firebase
║     13 locations rollout (Jan 7-14)
║
╠══════════════════════════════════════════════════════════════╣
║  Total Missions: 5 | Active: 2 | Blocked: 1 | Queued: 2
╚══════════════════════════════════════════════════════════════╝
```

### 2. Kanban Board Update

Updates the team's kanban board file:

**File:** Each team's distributed kanban directory (paths loaded from `aiteamforge_paths.py` via `server.py`), e.g.:
- Academy: `<academy-repo>/kanban/academy-board.json`
- iOS: `<ios-repo>/kanban/ios-board.json`
- Firebase: `<firebase-repo>/kanban/firebase-board.json`

**Updated Field:** `backlog` array

```json
{
  "team": "ios",
  "backlog": [
    {
      "id": "IOS-001",
      "title": "Package Purchases",
      "priority": "high",
      "status": "in_progress",
      "description": "Enable package purchases in mobile app",
      "addedAt": "2026-01-02T14:30:00Z"
    }
  ]
}
```

---

## Processing Logic

### Step 1: Detect Team

```python
def detect_team():
    # Check environment variable
    if os.environ.get('LCARS_TEAM'):
        return os.environ['LCARS_TEAM']

    # Check terminal name against the built-in ids plus every team id in the
    # registry (~/.aiteamforge/team-paths.json "teams"), so fleet-specific teams
    # such as a coordination team are detected without being named here.
    terminal = get_terminal_name()
    known = ['ios', 'android', 'firebase', 'academy', 'command', 'dns', 'freelance']
    try:
        with open(os.path.expanduser('~/.aiteamforge/team-paths.json')) as f:
            # Shortest first, so 'coord-ios' resolves to the base team 'coord'.
            known += sorted(json.load(f).get('teams', {}), key=len)
    except (OSError, ValueError):
        pass
    for team in known:
        if terminal.startswith(team):
            return team

    # Check working directory (use $IOS_REPO, $ANDROID_REPO, $FIREBASE_REPO env vars,
    # or fall back to git remote / platform-file detection)
    cwd = os.getcwd()
    ios_repo = os.environ.get('IOS_REPO', '')
    android_repo = os.environ.get('ANDROID_REPO', '')
    firebase_repo = os.environ.get('FIREBASE_REPO', '')
    if ios_repo and cwd.startswith(ios_repo):
        return 'ios'
    elif android_repo and cwd.startswith(android_repo):
        return 'android'
    elif firebase_repo and cwd.startswith(firebase_repo):
        return 'firebase'

    # Default to academy
    return 'academy'
```

### Step 2: Gather Missions (Intelligent Update)

**IMPORTANT:** The skill checks existing backlog items and updates them rather than blindly creating new ones. This preserves existing mission IDs, descriptions, and metadata.

```python
def gather_missions(team):
    missions = []

    # 1. Read existing backlog - PRESERVE existing items
    existing = read_kanban_backlog(team)
    existing_by_title = {m['title']: m for m in existing}

    # 2. Extract from active session todos
    session_tasks = extract_session_tasks(team)

    # 3. Check SESSION_STATUS.md for pending items
    status_tasks = parse_session_status()

    # 4. Analyze git status for in-progress work
    git_tasks = analyze_git_status()

    # 5. Merge with intelligent update logic
    return merge_missions_intelligently(existing, session_tasks, status_tasks, git_tasks)

def merge_missions_intelligently(existing, *new_sources):
    """
    Merge new missions with existing ones:
    - If mission with same title exists: UPDATE it (preserve id, addedAt, add new info)
    - If mission is new: CREATE with next available ID and current timestamp
    - Preserve descriptions, addedAt, and other metadata from existing items
    """
    result = {m['id']: m for m in existing}

    for source in new_sources:
        for task in source:
            # Check if similar mission exists (by title match)
            match = find_matching_mission(task, existing)
            if match:
                # Update existing mission, preserve description and addedAt
                update_mission(result[match['id']], task)
            else:
                # Create new mission with new ID and timestamp
                new_id = generate_next_id(result.keys())
                task['id'] = new_id
                task['addedAt'] = datetime.utcnow().isoformat() + 'Z'  # REQUIRED: ISO 8601 timestamp
                result[new_id] = task

    return list(result.values())
```

### Step 3: Classify and Prioritize

```python
def classify_mission(task):
    # Determine priority based on task attributes
    if task.get('status') == 'blocked':
        priority = 'high'  # Blocked items need attention
    elif task.get('priority') == 'critical':
        priority = 'critical'
    elif task.get('status') == 'in_progress':
        priority = 'high'
    else:
        priority = 'medium'

    # Determine status from task state
    status = task.get('status', 'todo')

    return priority, status
```

### Step 4: Update Kanban Board

```python
def update_kanban_backlog(team, missions):
    # Use distributed TEAM_KANBAN_DIRS mapping (see server.py)
    board_file = get_board_file(team)  # Resolves to team-specific kanban directory

    # Read current board
    with open(board_file, 'r') as f:
        board = json.load(f)

    # Update backlog
    board['backlog'] = missions

    # Write back
    with open(board_file, 'w') as f:
        json.dump(board, f, indent=2)
```

---

## Cross-Team Coordination

### Coordination Mission Detection

A mission is considered a "coordination mission" if:

1. **Explicit Coordination Field:** Has `coordination` array specified
2. **Title Pattern:** Contains "[iOS+Android]" or similar
3. **Multiple Team References:** Description mentions multiple teams
4. **Cross-Platform Feature:** Feature requires iOS, Android, and/or Firebase work

### Including Coordination Missions

When `--with-coordination` flag is set:

1. Scan existing backlog for coordination fields
2. Filter to only include those relevant to current team
3. Add `coordination` field listing other involved teams
4. Display in separate "Coordination Missions" section

### Example Coordination Mission

```json
{
  "id": "COORD-001",
  "title": "Cross-Platform Rollout Epic",
  "priority": "medium",
  "status": "todo",
  "category": "feature",
  "description": "Rollout across 13 locations (Jan 7-14)",
  "coordination": ["ios", "android", "firebase"],
  "addedAt": "2026-01-02T09:00:00Z"
}
```

---

## Team-Specific Configurations

### iOS Team (TNG)

**Kanban Board:** `ios-board.json`
**Project Directory:** `<ios-repo>/` (auto-detected from $IOS_REPO or terminal context)
**Personas:** Picard, Geordi, Worf, Troi, Crusher, Data

**Mission Categories:**
- Features: New app functionality
- Bugs: Bug fixes and crash resolution
- Releases: TestFlight/App Store releases
- Technical: Force unwrap elimination, refactoring

### Android Team (TOS)

**Kanban Board:** `android-board.json`
**Project Directory:** `<android-repo>/` (auto-detected from $ANDROID_REPO or terminal context)
**Personas:** Kirk, Spock, McCoy, Scotty, Uhura, Chekov, Sulu

**Mission Categories:**
- Features: New app functionality
- Bugs: Bug fixes and crash resolution
- Releases: Play Store releases
- Technical: Compose migration, dependency updates

### Firebase Team (DS9)

**Kanban Board:** `firebase-board.json`
**Project Directory:** `<firebase-repo>/` (auto-detected from $FIREBASE_REPO or terminal context)
**Personas:** Sisko, O'Brien, Odo, Dax, Kira, Bashir, Quark

**Mission Categories:**
- Features: Cloud Functions features
- Security: Security rules updates
- Performance: Query optimization, cost reduction
- Technical: Firebase SDK updates

### Academy Team (DSC - 32nd Century)

**Kanban Board:** `academy-board.json`
**Project Directory:** the Academy team's `working_dir` from the team registry (`~/.aiteamforge/team-paths.json`)
**Personas:** Nahla Ake, Jett Reno, EMH, Lura Thok

**Mission Categories:**
- Infrastructure: LCARS UI, kanban system
- Documentation: Team guides, setup docs
- Training: Onboarding materials
- Tools: Skills, hooks, automation

### Command Team (DSC - 32nd Century)

**Kanban Board:** `command-board.json`
**Project Directory:** Various (oversight role)
**Personas:** Vance, Ross, Nechayev, Janeway, Paris

**Mission Categories:**
- Strategic: Planning, roadmaps
- Reporting: Weekly updates, stakeholder comms
- Coordination: Cross-team alignment
- Operations: Release coordination

### DNS Framework Team (Lower Decks)

**Kanban Board:** `dns-board.json`
**Project Directory:** DNS Framework packages
**Personas:** Mariner, T'Ana, Shaxs, Rutherford, Tendi, Boimler, Ransom

**Mission Categories:**
- Features: Package features
- Bugs: Package bug fixes
- API: API design updates
- Documentation: Package docs

### Freelance Team (ENT)

**Kanban Board:** `freelance-{group}-{project}-board.json` (project-isolated)
**Project Directory:** `<projects-root>/{Group}/{Project}/`
**Personas:** Archer, Tucker, T'Pol, Phlox, Reed, Sato, Mayweather

**Board Examples:**
- `freelance-<group>-<project-a>-board.json` - first project
- `freelance-<group>-<project-b>-board.json` - second project

**Team Detection:**
Session name like `freelance-<group>-<project>-command` extracts:
- Team: `freelance-<group>-<project>`
- Terminal: `command`

**Mission Categories:**
- Features: Client feature work
- Releases: App Distribution
- Technical: Cross-platform tools
- Documentation: Client deliverables

---

## Error Handling

### Team Detection Failure

```
⚠️  Could not auto-detect team.

Please specify team explicitly:
  kb-backlog ios
  kb-backlog android
  kb-backlog firebase
  kb-backlog academy
  kb-backlog command
  kb-backlog dns
  kb-backlog freelance
```

### Empty Mission Queue

```
✅ No pending missions found for [Team Name].

All clear, Captain! The team's mission queue is empty.

To add missions:
1. Add items to SESSION_STATUS.md
2. Create todos in active sessions
3. Manually add to backlog with kb-backlog --add "Mission title"
```

---

## Integration with LCARS UI

The updated backlog is immediately visible in the LCARS dashboard:

1. **LCARS Server** reads kanban board JSON
2. **Backlog Section** displays missions from `backlog` array
3. **Priority Colors** match mission priority levels
4. **Status Icons** indicate mission state

**Refresh Behavior:**
- LCARS UI polls board every 5 seconds
- Changes appear automatically after `kb-backlog` execution

---

## Skill Limitations

### What This Skill Does NOT Do

1. **Does not create external issues** - Only manages local kanban
2. **Does not assign missions to terminals** - That's manual
3. **Does not execute missions** - Just tracks them
4. **Does not modify other team's boards** - Team-isolated
5. **Does not sync to external systems** - Local only

### When to Use This Skill

✅ **Use when:**
- Starting a new work session
- Refreshing mission priorities
- Checking team workload
- Onboarding to current team state
- Updating backlog from session work

❌ **Don't use for:**
- Cross-team mission assignment
- Historical reporting
- External stakeholder communication

---

## Version History

**v1.8.0** (January 7, 2026)
- **Clickable tag pills** - Missions and subitems can now have categorization tags
- New `tags` field on missions and subitems (array of strings)
- New `kb-backlog tag` command (add, rm, clear, set)
- New `kb-backlog sub tag` command for subitem tags
- Tags display as purple pills with black vertical separators in LCARS UI
- Click any tag to filter mission queue by that tag
- Search includes tag text matching
- Recommended tag types: platform (iOS, Android), category (feature, bugfix), sprint, component

**v1.7.0** (January 7, 2026)
- **Due date support** - Missions can now have target completion dates
- New `dueDate` field in mission object (ISO 8601 format: YYYY-MM-DD)
- New `kb-backlog due` command for viewing/setting/clearing due dates
- Natural language date parsing: `tomorrow`, `next friday`, `+7d`, `+2w`
- Due date as 6th parameter on add command
- Visual urgency indicators in LCARS UI: OVERDUE (pulsing red), TODAY (orange), SOON (yellow)
- Priority boost: overdue items sort to top within their priority group
- Items due today sort before items due later

**v1.6.0** (January 7, 2026)
- **Automatic subitem expansion** - Intelligently expands complex missions into subitems
- New expansion trigger criteria: category-based, complexity keywords, list detection, cross-team coordination
- New expansion templates: feature, epic, release, refactor, migration, bugfix
- New `kb-backlog expand` and `kb-backlog unexpand` commands
- New `--expand` and `--no-expand` flags for add command
- Smart detection of when NOT to expand (simple fixes, blocked items, existing subitems)
- Priority-based expansion rules (critical always expands, blocked never expands)
- Description list parsing (bullets, numbered lists, semicolons)
- Cross-team coordination auto-generates platform-specific subitems

**v1.5.0** (January 6, 2026)
- Added hierarchical subitems support for missions
- New `subitems` array field in mission object
- Subitems have own JIRA/GitHub links (independent from parent)
- New `kb-backlog sub` command with subcommands: add, list, remove, done, todo, jira, github, start
- New `kb-backlog toggle` command for collapsed/expanded state
- `collapsed` field persists UI state in JSON
- LCARS UI shows expandable missions with ▶/▼ indicators
- Completion badge shows ratio (e.g., "2/5")
- Subitem statuses: todo, in_progress, completed
- `sub start` promotes subitem to activeWindow for active work

**v1.4.0** (January 5, 2026)
- Added GitHub issue support for teams without an internal JIRA backend
- New `githubIssue` field in mission object
- New `kb-backlog github` command (alias: `gh`)
- Supports shorthand `#123` (uses team default repo) and full `owner/repo#123` format
- Team default repos: configured per team (academy, dns)
- GitHub links displayed in purple, JIRA in blue

**v1.3.0** (January 5, 2026)
- Added JIRA ID support with tappable links in LCARS UI
- New `jiraId` field in mission object (4th parameter on add)
- New `kb-backlog jira` command for viewing/setting/clearing JIRA IDs
- Added CRITICAL priority (red pulsing indicator, sorted first)
- Added BLOCKED priority (gray with ⏸ icon, sorted last)
- Priority shortcuts: `crit` for critical, `block` for blocked
- Updated sort order: critical → high → medium → low → blocked
- JIRA links open in new tab pointing to team's Atlassian instance

**v1.2.0** (January 2, 2026)
- Added `addedAt` as required field for all missions (ISO 8601 timestamp)
- New missions automatically get current timestamp when created
- Existing missions preserve their `addedAt` during updates
- Fixes LCARS UI showing dash when timestamp was missing

**v1.1.0** (January 2, 2026)
- Added description support for missions
- New `kb-backlog add "title" priority "description"` syntax (3rd parameter)
- New `kb-backlog desc` command for viewing/setting/clearing descriptions
- Intelligent update logic: checks existing backlog items before creating new ones
- Preserves mission IDs and descriptions when updating existing items

**v1.0.0** (January 2, 2026)
- Initial release
- Team auto-detection from terminal context
- Kanban board backlog updates
- Session todos and git status integration
- Cross-team coordination mission support
- LCARS-style console output
- All 7 teams supported

---

## Support & Feedback

**Skill Author:** Captain Nahla Ake (Starfleet Academy Chancellor)

**Usage Questions:**
- How do I generate missions for my team?
- How do I include coordination missions?
- How do I manually add missions?
- How do I sync missions between teams?

**Command Shortcut:** `kb-backlog`

---

*"The future of Starfleet depends on those we train today." - Captain Nahla Ake*
