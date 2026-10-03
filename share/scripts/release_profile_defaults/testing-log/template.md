# v{{release.version}} - {{release.id}} - {{release.platform}} Testing Log

**Release:** {{release.id}} | **Platform:** {{release.platform}} | **Version:** {{release.version}} | **Current stage:** {{release.currentStage}}

{{#if gammaFailure.active}}
**GAMMA failure:** {{gammaFailure.summary}}. Production was rolled back to {{gammaFailure.rollbackSha}}; the release returns to DEV for the fix and ships under a new Change Request.

{{/if}}
{{#if gammaFailure.regressed}}
**Earlier GAMMA failure (build {{gammaFailure.failedSha}}):** {{gammaFailure.summary}}. Production was rolled back to {{gammaFailure.rollbackSha}}; the release was returned to DEV for the fix, which ships under a new Change Request.

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
