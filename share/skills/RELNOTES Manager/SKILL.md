---
name: relnotes-manager
description: Manages RELNOTES lifecycle for any product/team through a configurable environment pipeline (e.g., DEV → QA → PROD). Use when updating RELNOTES-DEV, promoting between environments, generating App Store or store-listing assets, creating PM summaries, or coordinating multi-platform releases.
model: sonnet
---

# RELNOTES Manager

## Skill Metadata

**Name:** RELNOTES Manager
**Version:** 1.0.0
**Author:** Configure for your team
**Primary Terminal:** Assign to your release engineer persona
**Also Used In:** Any platform engineering terminal that needs RELNOTES management
**Platforms:** Configurable — iOS, Android, backend services, or any combination
**Last Updated:** Configure for your team

---

## Purpose

This skill manages the progressive release notes lifecycle for any product across one or more platforms. It handles incremental RELNOTES-DEV updates, environment promotions through a configurable deployment pipeline (e.g., DEV → QA → ALPHA → BETA → GAMMA → PROD), generates store listing assets (e.g., App Store or Google Play), creates platform-specific PM summaries and stakeholder briefs, and coordinates cross-platform release documentation with marketing campaign integration.

Configure the pipeline stages, platforms, and file locations to match your team's workflow.

**This skill focuses exclusively on version-specific release documentation tied to product deployments.**

---

## Core Capabilities

### 1. Progressive Release Notes Management
- **Incremental Updates:** Accumulates changes in RELNOTES-DEV.md without overwriting
- **Environment Promotion:** Promotes release notes through deployment pipeline
- **Format Preservation:** Maintains exact technical format and structure
- **Cross-Platform Coordination:** Handles synchronized releases across platforms

### 2. Store Listing Content
- **Primary Language:** Promotional and changelog content in your primary locale
- **Additional Locales:** Generate translations for each locale your product ships in (configure per team)
- **Terminology Consistency:** Preserves your product's established vocabulary
- **Character Limits:** Enforces App Store / Google Play character restrictions (<4000 chars)

### 3. Release-Specific Documentation
- **Technical PM Summary:** Detailed technical implementation summary per release
- **Stakeholder Brief:** Business-friendly release summary with marketing tie-ins
- **Marketing Integration:** Incorporates relevant campaigns from MARKETING.md
- **Impact Analysis:** Expected improvements and business value per release

### 4. Release Classification
- **Type Detection:** FEATURE vs. CRITICAL BUGFIX vs. BUGFIX
- **Crash Tracking:** Firebase Crashlytics issue counting and categorization
- **Jira Integration:** PROJ-xxx issue references with descriptions
- **Known Issues:** Limitations and upcoming fixes

---

## File Structure

### Per-Platform Release Documentation

Each platform project maintains its own release notes. Configure paths to match your repo layout. Example structure:

```
<your-project-root>/
├── <platform-a>/                    # e.g., ios/, android/, backend/
│   ├── RELNOTES-DEV.md          # Living document, updated as work completes
│   ├── RELNOTES-QA.md           # Promoted from DEV for QA environment
│   ├── RELNOTES-ALPHA.md        # Promoted from QA for alpha testing (optional)
│   ├── RELNOTES-BETA.md         # Promoted from ALPHA for beta testing (optional)
│   ├── RELNOTES-GAMMA.md        # Promoted from BETA for pre-production (optional)
│   ├── RELNOTES-PROD.md         # Final production with store listing assets
│   └── docs/
│       └── project/
│           ├── pm-summary.md           # Platform-specific PM summary
│           └── stakeholder-brief.md    # Platform-specific brief
│
├── <platform-b>/
│   └── [same structure]
│
└── docs/
    └── project/
        └── MARKETING.md       # Centralized marketing campaigns (if applicable)
```

### Directory Organization Philosophy

**Platform-Specific Docs** (`<platform>/docs/project/`):
- PM summaries for single-platform releases
- Stakeholder briefs for platform-specific features
- Located with the platform's source code
- Tied to specific version numbers

**MARKETING.md Location:**
- Centralize in a shared docs directory or a dedicated assets repo (configure per team)
- Single source of truth for all marketing campaign data
- Skill reads this file for all marketing integration needs

---

## Release Notes Format Specification

### RELNOTES-DEV through RELNOTES-GAMMA Format

```markdown
════════════════════════════════════════
## [ENVIRONMENT] - [VERSION]

**Release Type**
-   [FEATURE | CRITICAL BUGFIX | BUGFIX]

**Issues Resolved**
-   **Critical Crash Fixes ([N] Production Crashes)**
    -   Fixed Crash #[ID]: [Description]
    -   [Additional crashes...]
-   **Jira Issues**
    -   PROJ-[ID]: [Description]
    -   [Additional issues...]

**New Features**
-   **[Feature Name] (PROJ-[ID])**
    -   [Detailed implementation description]
    -   [Sub-features or components]
    -   [Technical details]

**Technical Improvements** (optional)
-   [Performance enhancements]
-   [Architecture improvements]
-   [Code quality updates]

**Known Problems and/or Limitations**
-   [Issue description and workaround/timeline]
-   [Additional known issues...]

════════════════════════════════════════
```

### RELNOTES-PROD Additional Sections (at top)

```markdown
════════════════════════════════════════
## PROD - [VERSION]

**Store Promo (primary locale)**
[Promotional text, <4000 chars, highlighting key new feature or offer]

**Store What's New (primary locale)**
-   [Bullet point 1: Most important feature/fix]
-   [Bullet point 2: Secondary features]
-   [Bullet point 3-5: Additional improvements]
-   [Typically 3-7 bullets, concise and user-friendly]

**Store Promo (additional locale, if applicable)**
[Translation of promotional text for each configured locale]

**Store What's New (additional locale, if applicable)**
-   [Translation of bullets for each configured locale]

[... then standard format continues as above ...]
════════════════════════════════════════
```

---

## Trigger Phrases & Commands

### Progressive RELNOTES-DEV Updates

**Command Pattern:** `"Update RELNOTES-DEV: [description]"`

**Examples:**
- `"Update RELNOTES-DEV: Fixed Crash #1234 with database serialization lock"`
- `"Update RELNOTES-DEV: Added PROJ-429 iOS 26 design system foundation"`
- `"Update RELNOTES-DEV: Performance improvement - reduced app launch time by 30%"`

**Behavior:**
- Appends to appropriate section (Issues Resolved, New Features, Technical Improvements)
- Automatically categorizes as crash fix, feature, or improvement
- Maintains chronological order within sections
- Preserves existing content (accumulative, not replacement)
- Updates crash count if applicable
- Determines release type (FEATURE if new features exist, CRITICAL BUGFIX if multiple crashes, else BUGFIX)

### Environment Promotion

**Command Pattern:** `"Promote RELNOTES_[SOURCE] to RELNOTES_[DEST] for [platform] [version]"`

**Examples:**
- `"Promote RELNOTES-DEV to RELNOTES-QA for iOS 2.8.0"`
- `"Promote RELNOTES-BETA to RELNOTES-GAMMA for Android build 1.5.2"`
- `"Promote RELNOTES-GAMMA to RELNOTES-PROD for Firebase v3.1.0"`

**Behavior:**
- Copies content from source environment to destination
- Updates environment header (e.g., DEV â†’ QA)
- For PROD promotion: Generates store listing assets at top (for each configured locale)
- Preserves all technical content
- Maintains formatting and structure
- Creates backup of destination file before overwriting

### Production Release Generation

**Command Pattern:** `"Generate production release docs for [platform] v[version]"`

**Examples:**
- `"Generate production release docs for iOS v2.8.0"`
- `"Generate production release docs for Android v1.5.2 with marketing tie-ins"`
- `"Generate full release package for Firebase v3.1.0"`

**Behavior:**
- Promotes RELNOTES-GAMMA to RELNOTES-PROD (or the highest pre-production stage in your pipeline)
- Generates store listing assets in each configured locale
- Creates pm-summary.md in `<platform>/docs/project/`
- Creates stakeholder-brief.md in `<platform>/docs/project/`
- Incorporates relevant campaigns from MARKETING.md if present
- Calculates expected impact and business value
- **Reminder:** If your team has a Change Request generation skill (e.g., a team-specific `/cr` skill), invoke it after generating production release docs to create the required Change Request for the PROD deployment; otherwise generate CR documentation manually from RELNOTES.

### Marketing Integration

**Command Pattern:** `"Generate stakeholder brief for [platform] [version] with marketing tie-ins"`

**Examples:**
- `"Generate stakeholder brief for iOS 2.8.0 with holiday campaign"`
- `"Update stakeholder brief to include Black Friday promotion"`

**Behavior:**
- Reads MARKETING.md from configured location (default: `<project-root>/docs/project/MARKETING.md`)
- Reads platform-specific marketing notes if present
- Identifies relevant marketing initiatives for release timeline
- Integrates campaign messaging with technical features
- Creates executive-friendly summary in `<platform>/docs/project/`
- Highlights business value and promotional opportunities

### Cross-Platform Coordination

**Command Pattern:** `"Coordinate release docs for <platform-a> [v1] + <platform-b> [v2] + <platform-c> [v3]"`

**Examples:**
- `"Coordinate release docs for iOS 2.8.0 + Android 1.5.2 + backend 3.1.0"`

**Behavior:**
- Generates synchronized release documentation across all configured platforms
- Creates unified stakeholder brief in `<project-root>/docs/reports/`
- Highlights cross-platform features and improvements
- Consolidates marketing opportunities
- Produces combined PM summary in central reports directory
## Locale / Translation Rules

If your product ships to multiple locales, configure translation requirements here. The following guidelines apply generically regardless of target language.

### Core Terminology Preservation

Create a terminology table for your product's brand-specific terms that must NOT be translated (product names, feature names, etc.). Example structure:

| Source Term | Target Locale Term | Notes |
|-------------|-------------------|-------|
| [Brand Name] | [Brand Name] | Brand name — DO NOT translate |
| [Feature Name] | [Feature Name] | Product feature — DO NOT translate |
| [Technical term] | [Locale equivalent] | Standard technical term |

### Translation Quality Standards

1. **Professional Tone:** Use the appropriate formality register for your locale conventions
2. **Technical Accuracy:** Preserve technical meaning while being user-friendly
3. **Locale Conventions:** Follow the specific conventions for each target locale
4. **Character Count:** Match or be slightly shorter than source language version
5. **Punctuation:** Use locale-appropriate punctuation conventions
6. **Numbers:** Use locale-appropriate number formatting

### Translation Process

1. **Translate primary-language promo/changelog first**
2. **Verify terminology consistency** with existing translations
3. **Check character count** (<4000 total for App Store; verify platform limits)
4. **Preserve bullet point structure** exactly
5. **Maintain technical accuracy** while being user-friendly
6. **Use active voice** when possible
7. **Verify locale-specific punctuation and formatting**

---

## Processing Rules

### Incremental Update Rules

When updating RELNOTES-DEV:

1. **Identify Target Section:**
   - Crash fixes â†’ "Issues Resolved" under "Critical Crash Fixes"
   - Jira issues â†’ "Issues Resolved" under "Jira Issues"
   - New features â†’ "New Features"
   - Performance/architecture â†’ "Technical Improvements"

2. **Append, Don't Overwrite:**
   - Add new content to end of appropriate section
   - Maintain chronological order (newest at bottom)
   - Preserve all existing content
   - Keep section headers intact

3. **Auto-Classification:**
   - If adding crash fix â†’ Ensure "Critical Crash Fixes" subsection exists
   - Update crash count in subsection header: `(N Production Crashes)` â†’ `(N+1 Production Crashes)`
   - If adding PROJ-xxx â†’ Create Jira Issues subsection if needed
   - If adding new feature â†’ Update Release Type to FEATURE
   - If adding multiple crash fixes (3+) â†’ Update Release Type to CRITICAL BUGFIX

4. **Format Preservation:**
   - Maintain exact indentation (4 spaces for sub-items)
   - Keep line separators (â”â”â”) unchanged
   - Preserve bold/italic formatting
   - Keep bullet point style consistent

### Environment Promotion Rules

When promoting between environments:

1. **Source Validation:**
   - Verify source RELNOTES exists and is not empty
   - Confirm source environment is one level below destination
   - Check that version numbers are consistent

2. **Content Transfer:**
   - Copy entire content block between separators
   - Update environment header (e.g., DEV â†’ QA)
   - Preserve all formatting and structure
   - Do not modify technical content

3. **PROD Promotion Special Rules:**
   - Generate store listing assets at top (before technical content)
   - Create promotional text for each configured locale (<4000 chars)
   - Generate concise changelog bullets (3-7 items, user-friendly language)
   - Translate to each additional configured locale
   - Insert before existing technical sections
   - **Generate Change Request:** After promoting to PROD, if your team has a Change Request generation skill (e.g., a team-specific `/cr` skill), invoke it to generate the deployment CR; otherwise generate CR documentation manually from RELNOTES-DEV.

4. **Backup Creation:**
   - Create timestamped backup of destination file before overwriting
   - Format: `RELNOTES_[ENV]_backup_[YYYYMMDD_HHMMSS].md`

### Release Type Detection

Algorithm for determining Release Type:

```
IF (New Features section has content)
    Release Type = FEATURE
ELSE IF (Critical Crash Fixes count >= 3)
    Release Type = CRITICAL BUGFIX
ELSE IF (Issues Resolved section has content)
    Release Type = BUGFIX
ELSE
    Release Type = MAINTENANCE
```

### App Store Asset Generation Rules

When generating App Store content for RELNOTES-PROD:

1. **Promotional Text (primary locale):**
   - Lead with strongest value proposition
   - Mention any active promotions/offers
   - Call to action at end
   - Maximum 200 words (typically 50-100)
   - Casual but professional tone
   - Focus on user/customer benefits

2. **What's New Bullets (primary locale):**
   - 3-7 bullet points maximum
   - Lead with most impactful change
   - User-friendly language (avoid technical jargon)
   - Group related fixes ("Fixed 7 crashes" not individual crash bullets)
   - Include performance/visual improvements
   - End with general improvements if needed

3. **Additional Locale Translations:**
   - For each configured locale, translate promotional text preserving tone and length
   - Translate bullets maintaining structure
   - Verify terminology consistency against your product's terminology table
   - Check character count remains <4000 (verify per platform)
   - Use locale-appropriate punctuation

4. **Content Prioritization:**
   - **Priority 1:** New features (user-visible)
   - **Priority 2:** Critical crash fixes (stability)
   - **Priority 3:** Performance improvements
   - **Priority 4:** Visual refinements
   - **Priority 5:** Bug fixes (non-crash)

5. **Example Transformation:**

   **From Technical (RELNOTES-DEV):**
   ```
   - Fixed Crash #1234: database thread-safety crash in account loading
   - Fixed Crash #3401: Force unwrap crash in booking confirmation
   - Fixed Crash #3422: Memory leak in leaderboard view
   ```

   **To User-Friendly (RELNOTES-PROD):**
   ```
   - Fixed 7 critical crashes improving app stability
   ```

---


---

## Marketing Integration Logic

### MARKETING.md Structure

Expected format:
```markdown
### [Campaign Name]
**Duration:** [Start Date] - [End Date]
**Channel:** [In-app | Email | Social Media | etc.]
**Focus:** [Campaign focus areas]
**App Relevance:**
- [How this campaign relates to app features]
- [What's needed in app]
**Talking Points for Stakeholders:**
- [Key messages to emphasize]
```

### MARKETING.md Location

**Centralized Source:** `<project-root>/docs/project/MARKETING.md` (configure to match your repo layout)
- Centralized marketing campaigns managed by Marketing team
- Contains all company-wide campaigns across all platforms
- This is the single source of truth for marketing initiatives
- Skill reads this file for all marketing integration

### Integration Process

1. **Read MARKETING.md:**
   - Parse all campaign entries
   - Identify campaigns with overlapping release timeline
   - Extract app-relevant campaigns only

2. **Match to Features:**
   - Cross-reference campaign focus with new features in release
   - Identify existing app features supporting campaigns
   - Flag missing app features needed for campaigns

3. **Generate Stakeholder Messaging:**
   - Link technical features to marketing campaigns
   - Create business value statements
   - Suggest promotional angles
   - Highlight timing opportunities

4. **Example Integration:**

   **From MARKETING.md:**
   ```
   ### Holiday Promotion
   **Duration:** November 15 - December 31
   **Focus:** Holiday purchases, gift card sales
   **App Relevance:**
   - Gift card purchase flow (already in app)
   - Holiday-themed UI (not implemented yet)
   **Talking Points:**
   - "Our faster checkout is perfect for holiday gift card buyers"
   ```

   **From RELNOTES-PROD (Technical):**
   ```
   **New Features**
   - Checkout Performance Optimization (<TICKET-ID>)
     - Reduced checkout time from 8 seconds to 3 seconds
     - Improved payment gateway integration
   ```

   **Stakeholder Brief Output:**
   ```
   ### Marketing Tie-In: Holiday Promotion
   
   Our v2.8.0 release perfectly supports the upcoming Holiday Promotion
   (Nov 15 - Dec 31). The new checkout optimization (3-second checkout
   vs. 8-second previously) significantly improves the gift card
   purchase experience, which is a core focus of the holiday campaign.
   
   **Talking Points for Customer Relations:**
   - "Users can now complete purchases 2.5x faster, making gift card
     purchases quick and seamless during busy holiday shopping"
   
   **Talking Points for Marketing:**
   - "Technical improvements support holiday campaign messaging about
     convenient gift giving"
   
   **Operations Note:**
   - Faster checkout will reduce wait times at kiosks during peak
     holiday traffic
   ```

### Generating "MARKETING ACTIONS NEEDED" Section

When generating Weekly Stakeholder Updates or Marketing Summary reports, the skill must analyze MARKETING.md to identify offers requiring Marketing team review or clarification.

**Analysis Required:**

1. **Potential Duplicate Offers:**
   - Scan for offers with similar names or identical functionality
   - Example: `winterSale` appearing twice or overlapping with `seasonalSale`
   - Flag any offer ID appearing in multiple campaign entries
   - Compare campaign descriptions for semantic similarity

2. **Offers Without Specific End Dates:**
   - Identify offers with "End Date: TBD" or "ongoing promotion"
   - Flag offers with "Start Date: Unknown"
   - List offers running for extended periods (>6 months) without review date

3. **Limited Distribution Offers:**
   - Single-location offers (e.g., `pilotOffer` at one location only)
   - Offers with fewer than 5 participating locations
   - Offers excluding more than 3 locations

4. **Geographic Exclusions Requiring Verification:**
   - Any offer using an exclusion list (e.g., `notLocations[]`)
   - Offers excluding a specific market
   - Offers with market-specific restrictions

**Output Format:**

For each category, generate:
- **Offer ID and Priority** (from MARKETING.md)
- **Current Status** (dates, distribution, exclusions)
- **Action Needed** (question to be answered)
- **Questions** (specific items requiring clarification)
- **Impact** (if relevant - user confusion, operational complexity)

**Action Items Summary:**

Categorize findings into High/Medium/Low priority based on:
- **High:** Potential duplicates, single-location pilots needing expansion decision
- **Medium:** Geographic exclusion verification, ongoing offers without end dates
- **Low:** Campaign lifecycle policy, performance metric establishment

**Next Steps:**

Always include:
1. Marketing team reviews flagged offers
2. Provides clarification or updates to Development team
3. Development team updates MARKETING.md and Firebase configurations
4. Remove resolved items from next week's report

**Template Variables:**

Replace template placeholders `[Analyze MARKETING.md...]` with actual findings from your configured MARKETING.md location (default: `<project-root>/docs/project/MARKETING.md`).

**Important:** Only include items that actually exist in MARKETING.md. If no duplicates found, state "No duplicate offers identified this week." Same for other categories.

---


---

## Document Templates

### PM Summary Template (pm-summary.md)

```markdown
# Technical Release Summary
## [Platform] v[Version] - [Release Type]

**Release Date:** [Date]  
**Environment:** PROD  
**Build Number:** [Build]  
**Previous Version:** [Previous]

---

## Executive Summary

[2-3 paragraph overview of release scope, key features, and expected impact]

---

## Features Delivered

### [Feature Name] (PROJ-[ID])

**Business Value:** [Why this matters to the business]

**Technical Implementation:**
- [Component 1]: [Description]
- [Component 2]: [Description]
- [Additional components...]

**User Impact:** [How users experience this feature]

**Success Metrics:** [How we'll measure success]

---

## Defects Resolved

### Critical Production Crashes ([N] Total)

| Crash ID | Description | Frequency | Root Cause | Fix |
|----------|-------------|-----------|------------|-----|
| #[ID] | [Description] | [N/day] | [Technical cause] | [Fix summary] |

### Jira Issues

| Issue ID | Description | Priority | Resolution |
|----------|-------------|----------|------------|
| PROJ-[ID] | [Description] | [P0/P1/P2] | [Fix summary] |

---

## Technical Improvements

- **Performance:** [Improvements to app speed, memory, battery]
- **Architecture:** [Structural improvements, tech debt paid down]
- **Code Quality:** [Test coverage, refactoring, patterns]

---

## Known Issues & Limitations

| Issue | Impact | Workaround | Timeline |
|-------|--------|------------|----------|
| [Description] | [Low/Med/High] | [If available] | [Expected fix version] |

---

## Testing Summary

**Test Coverage:**
- Unit Tests: [N tests, X% coverage]
- Integration Tests: [N tests]
- UI Tests: [N tests]
- Manual QA: [N hours, test cases]

**Environments Tested:**
- DEV: [Date, results]
- QA: [Date, results]
- ALPHA: [Date, results]
- BETA: [Date, results]
- GAMMA: [Date, results]

**Device Testing:**
- iOS: [Device list, OS versions]
- Real Device Testing: [Devices tested]

---

## Deployment Plan

**Rollout Strategy:** [Phased/Full/Emergency]

**Rollout Schedule:**
1. PROD deployment: [Date/Time]
2. App Store submission: [Date/Time]
3. App Store approval: [Expected date]
4. Public availability: [Expected date]

**Monitoring Plan:**
- Firebase Crashlytics: [Crash rate threshold]
- App Store ratings: [Monitor for issues]
- Customer Services: [Escalation protocol]

**Rollback Plan:** [If needed, how to revert]

---

## Business Impact Forecast

**Expected Improvements:**
- Crash Rate: [Current X/day â†’ Expected Y/day, Z% reduction]
- App Store Rating: [Current X.X â†’ Expected X.X]
- User Satisfaction: [Expected impact]
- Operational Efficiency: [Expected impact]

**Revenue Impact:** [If applicable, expected business value]

---

## Dependencies & Risks

**External Dependencies:**
- [Dependency 1]: [Status, risk level]
- [Dependency 2]: [Status, risk level]

**Risks:**
- [Risk 1]: [Probability, impact, mitigation]
- [Risk 2]: [Probability, impact, mitigation]

---

## Team & Effort

**Development Team:**
- iOS Lead: [Name]
- Contributors: [Names]

**Effort Summary:**
- Development: [N hours/days]
- Testing: [N hours/days]
- Documentation: [N hours/days]
- **Total:** [N hours/days]

---

## Next Release Preview

**Planned for v[Next]:**
- [Feature 1]: [Brief description]
- [Feature 2]: [Brief description]
- [Technical debt]: [Planned improvements]

**Target Date:** [Estimated]

---

**Prepared by:** [Your name]  
**Date:** [Date]  
**Questions/Contact:** [Email/Slack]
```

### Stakeholder Brief Template (stakeholder-brief.md)

```markdown
# Release Brief for Stakeholders
## [Platform] v[Version] - [Month Year]

**Audience:** Customer Relations, Marketing, Operations Leadership  
**Release Date:** [Date]  
**Previous Version:** [Version]

---

## What's New for Our Users

### Headline Features

**[Feature 1 Name]**
- **What It Does:** [Simple explanation in business terms]
- **User Benefit:** [Why users will love this]
- **Example:** [Real-world scenario showing value]

**[Feature 2 Name]**
- **What It Does:** [Simple explanation]
- **User Benefit:** [Why this matters]
- **Example:** [Real-world scenario]

### Improvements

- **Reliability:** [Crash fixes, stability improvements]
- **Speed:** [Performance improvements]
- **Polish:** [Visual refinements, UX improvements]

---

## Marketing Campaign Tie-Ins

### [Campaign Name] ([Dates])

**How This Release Supports the Campaign:**
[Explanation of how technical features enable or enhance marketing campaign]

**Suggested Talking Points:**

**For Customer Relations:**
- "[User-facing message about feature #1]"
- "[User-facing message about feature #2]"
- "[How to answer user questions about new features]"

**For Marketing Materials:**
- "[Marketing-friendly description of key feature]"
- "[Promotional angle for social media]"
- "[Email campaign messaging suggestion]"

**For Operations:**
- "[Operational impact or consideration]"
- "[Staff training needs, if any]"
- "[Expected user behavior changes]"

### [Additional Campaign, if applicable]

[Repeat structure above]

---

## Business Impact

### User Experience Improvements

**Faster Performance**
- [Key flow]: [Old time] â†’ [New time] ([X% faster])
- Impact: [Business value, e.g., "Reduced wait times during peak hours"]

**Reduced Crashes**
- Previous crash rate: [N crashes/day]
- Expected new rate: [N crashes/day] ([X% improvement])
- Impact: [Business value, e.g., "Fewer customer service calls"]

**[Additional Improvements]**
- [Metric]: [Before] â†’ [After]
- Impact: [Business value]

### Expected Outcomes

- **User Satisfaction:** [Expected impact on CSAT, NPS, reviews]
- **Operational Efficiency:** [Expected impact on Customer Services, operations]
- **Revenue:** [Expected impact if applicable]

---

## What Your Teams Should Know

### Customer Relations

**Anticipated Questions:**

Q: "Why does the app look different?"  
A: [Your answer]

Q: "[Expected question about new feature]"  
A: [Your answer]

**Known Issues to Be Aware Of:**
- [Issue 1]: [Description, workaround, timeline]
- [Issue 2]: [Description, workaround, timeline]

**Escalation Path:** [Who to contact for app-related user issues]

### Marketing

**Approved Messaging:**
- [Key message #1 for promotional materials]
- [Key message #2 for social media]
- [Call to action for app download campaigns]

**Assets Available:**
- App Store screenshots: [Location/contact]
- Feature demos/videos: [If available]
- Press release language: [If applicable]

**Don't Say:** [What to avoid in marketing materials]

### Operations

**Operational Impact:**
- [Impact #1, e.g., "Faster checkout flow reduces user wait times"]
- [Impact #2, e.g., "New leaderboard feature may increase engagement"]

**Staff Training Needs:**
- [Training need #1, if any]
- [Training need #2, if any]

**Monitoring:** [What to watch for in first week post-release]

---

## Technical Summary (Brief)

**What Changed:**
- [N] new features delivered
- [N] critical crashes fixed
- [N] performance improvements
- [N] visual refinements

**Quality Assurance:**
- Tested across [N] environments (DEV â†’ QA â†’ ALPHA â†’ BETA â†’ GAMMA)
- [N] devices tested
- [N] test cases executed
- [X%] test coverage

**Deployment:**
- Release to App Store: [Date]
- Expected public availability: [Date]
- Rollout strategy: [Phased/Full]

---

## Success Metrics

**We'll Track:**
- App Store rating (current: [X.X], goal: [X.X])
- Crash-free rate (current: [X]%, goal: [X]%)
- [Key feature] completion rate
- Customer Services app-related tickets
- [Platform-specific metrics]

**Check-In:** [When you'll report back with results]

---

## Questions?

**Technical Questions:** [PM contact]  
**Marketing Questions:** [Marketing contact]  
**Operations Questions:** [Operations contact]  
**Customer Relations Questions:** [Customer Relations contact]

---

**Prepared by:** [Your name]  
**Date:** [Date]  
**Version:** [Release version]
```


---

## Skill Limitations & Boundaries

### What This Skill Does NOT Do

1. **Does not write actual app code**
   - Skill manages documentation only
   - Does not generate Swift, Kotlin, or TypeScript code
   - Does not modify source files

2. **Does not directly interact with Jira or Firebase**
   - You must provide issue IDs and descriptions manually
   - Skill does not fetch issue details from Jira
   - Skill does not pull crash reports from Firebase Crashlytics

3. **Does not submit to App Store or Google Play**
   - Generates App Store/Play Store assets only
   - You must copy content to store portals manually
   - Skill does not handle binary uploads or metadata submission

4. **Does not replace human review**
   - Spanish translations should be verified by native speaker when possible
   - Marketing tie-ins should be reviewed by Marketing team
   - PM summaries should be reviewed by Product Manager before distribution

5. **Does not manage Git operations**
   - You must commit RELNOTES changes to Git yourself
   - Skill does not create branches or tags
   - Skill does not handle Git worktree operations

6. **Does not generate weekly reports**
   - This skill focuses on version-specific release documentation
   - Weekly status reports are handled by a separate team-specific reporting skill if one exists
   - See your team's reporting skill for weekly stakeholder updates

### When to Use This Skill

✅ **Use when:**
- Documenting completed work in RELNOTES-DEV
- Promoting release notes through deployment pipeline
- Generating production release materials (App Store assets)
- Creating PM summaries for specific releases
- Creating stakeholder briefs for specific releases
- Integrating technical features with marketing campaigns for a release
- Coordinating multi-platform releases

❌ **Don't use for:**
- Writing actual application code
- Debugging crashes or issues
- Fetching data from external systems (Jira, Firebase, etc.)
- Git commit/push operations
- App Store submission process
- Weekly status reporting (use your team's reporting skill instead)
- Marketing campaign planning (that's Marketing's job)

---

## Version History

**v1.0.0** (Initial release)
- **Scope:** Focused exclusively on RELNOTES lifecycle and version-specific release documentation
- **Features:**
  - Progressive RELNOTES-DEV through RELNOTES-PROD management
  - Configurable environment promotion pipeline
  - Multi-locale store listing asset generation
  - Configurable locale translation rules and terminology standards
  - Release type detection and classification
  - PM Summary template (per-platform, version-specific)
  - Stakeholder Brief template (per-platform, version-specific)
  - Marketing integration logic for releases
  - Cross-platform release coordination
  - Processing rules for incremental updates
  - Format preservation and validation
- **Excluded:** Weekly reports functionality (use a team-specific reporting skill)
- **Purpose:** Cleaner separation of concerns between release-specific docs and ongoing weekly reporting

---

## Support & Feedback

**Skill Maintainer:** Configure for your team

**Related Skills:**
- Team-specific reporting skill - Weekly reports and stakeholder communications (if applicable)
- Team-specific CR skill - Change Request generation for PROD deployments (if applicable)
- `git-worktree` - Git worktree management for parallel development

**Usage Questions:**
- How do I update RELNOTES-DEV with a new feature?
- How do I promote from one environment to another?
- How do I generate production release documentation?
- What's the format for Spanish translations?

