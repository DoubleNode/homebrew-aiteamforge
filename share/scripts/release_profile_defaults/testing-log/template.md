# v{{release.version}} - {{release.id}} - {{release.platform}} Testing Log

**Release:** {{release.id}} | **Platform:** {{release.platform}} | **Version:** {{release.version}} | **Current stage:** {{release.currentStage}}

{{#if rollback.sha}}
**GAMMA failure:** {{rollback.summary}}. Production was rolled back to {{rollback.sha}}; the release returns to DEV for the fix and ships under a new Change Request.

{{/if}}
## Scope

{{#each release.items}}
- {{this.title}}
{{/each}}

{{release.scopeNote?}}

## Test results by stage

### {{stage.name}}

| # | Timestamp (CT) | Type | Env | Test | Result | Run by | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
{{#each stage.tests}}
| {{this.n}} | {{this.timestampCT}} | {{this.type}} | {{this.env}} | {{this.test}} | {{this.result}} | {{this.runBy}} | {{this.notesWithShaAndSuperseded}} |
{{/each}}

**Stage totals:** {{stage.totals.automated}} automated, {{stage.totals.manual}} manual: {{stage.totals.pass}} pass / {{stage.totals.fail}} fail / {{stage.totals.waived}} waived.

## Waivers

{{#each waivers}}
- {{this.ts}} by {{this.by}}: {{this.reason}}
{{/each}}
