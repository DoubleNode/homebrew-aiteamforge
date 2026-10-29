# v{{release.version}} - {{release.id}} - {{release.platform}} Release & CR Status

## Status

| Field | Value |
| --- | --- |
| Release stage | {{status.stage}} |
| Change Request | {{status.cr}} |
| Testing Log | {{status.testingLog}} |
{{#if links.crRequestPage}}
| DPD2 CR Request | {{links.crRequestPage}} |
{{/if}}
| Last updated | {{status.updatedAtUTC}} |

**Generated page:** the release engine rewrites it after every release stage change and every Change Request state change. Manual edits will be refused on the next refresh; add notes as page comments instead.

## Header

| Field | Value |
| --- | --- |
| Platform | {{release.platform}} |
| Version | {{release.version}} |
| Release ID | {{release.id}} |
{{#if cr.id}}
| CR ID | {{cr.id}} |
| CR state | {{cr.state}} |
| Title | {{cr.title}} |
| Risk | {{cr.risk}} |
| Scheduled window | {{cr.scheduledWindow}} |
| Approver | {{cr.approver}}{{#if cr.approvalAssumed}} (assumed approval, basis: {{cr.approvalBasis}}){{/if}} |
{{/if}}

## Links

- Testing Log: {{status.testingLog}}
{{#if links.crRequestPage}}
- DPD2 CR Request: {{links.crRequestPage}}
{{/if}}
{{#each release.earlierRecords}}
- Earlier record ({{this.crId}}): {{this.url}}
{{/each}}

## Scope

{{#each release.items}}
- {{this.title}}
{{/each}}

## Release stage history

| Stage | Entered (CT) | Completed (CT) | Status |
| --- | --- | --- | --- |
{{#each release.stageHistory}}
| {{this.name}} | {{this.enteredAtCT}} | {{this.completedAtCT}} | {{this.status}} |
{{/each}}

## Change Requests

| CR | Title | State | Note | Request page |
| --- | --- | --- | --- | --- |
{{#each release.linkedCrs}}
| {{this.id}} | {{this.title}} | {{this.state}} | {{this.label}} | {{this.requestUrl}} |
{{/each}}

## CR state history

| CR | State | Verb | Actor | Timestamp (CT) | Note |
| --- | --- | --- | --- | --- | --- |
{{#each release.crHistory}}
| {{this.crId}} | {{this.state}} | {{this.verb}} | {{this.actor}} | {{this.timestampCT}} | {{this.note}} |
{{/each}}

## Notice receipts

| Sent | Provider | Alias | Result |
| --- | --- | --- | --- |
{{#each notices}}
| {{this.ts}} | {{this.provider}} | {{this.alias}} | {{this.ok}} |
{{/each}}
{{#if cr.id}}

## PROD deployment

| Field | Value |
| --- | --- |
| Deployed SHA | {{prod.deployedSha}} |
| Deploy time | {{prod.deployedAt}} |
| T+2h soak | {{prod.soak2h}} |
| T+24h soak | {{prod.soak24h}} |
{{/if}}
{{#if rollback.sha}}

## Exceptions

- GAMMA failure: {{rollback.summary}}
- Production was rolled back to {{rollback.sha}}.
- This Change Request was put on hold. The fix ships under a new Change Request, and this one is closed as superseded by it.
{{/if}}
