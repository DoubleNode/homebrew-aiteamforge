# v{{release.version}} - {{release.id}} - {{cr.id}}

## Header

| Field | Value |
| --- | --- |
| Platform | {{release.platform}} |
| Version | {{release.version}} |
| Release ID | {{release.id}} |
| CR ID | {{cr.id}} |
| Title | {{cr.title}} |
| Risk | {{cr.risk}} |
| Scheduled window | {{cr.scheduledWindow}} |
| Approver | {{cr.approver}}{{#if cr.approvalAssumed}} (assumed approval, basis: {{cr.approvalBasis}}){{/if}} |

## Links

- CR request page: {{links.crRequestPage}}
- Testing Log: {{links.testingLog}}

## Scope

{{#each release.items}}
- {{this.title}}
{{/each}}

## CR state history

| State | Verb | Actor | Timestamp (CT) | Note |
| --- | --- | --- | --- | --- |
{{#each cr.stateHistory}}
| {{this.state}} | {{this.verb}} | {{this.actor}} | {{this.timestampCT}} | {{this.note}} |
{{/each}}

## Notice receipts

| Sent | Provider | Alias | Result |
| --- | --- | --- | --- |
{{#each notices}}
| {{this.ts}} | {{this.provider}} | {{this.alias}} | {{this.ok}} |
{{/each}}

## PROD deployment

| Field | Value |
| --- | --- |
| Deployed SHA | {{prod.deployedSha}} |
| Deploy time | {{prod.deployedAt}} |
| T+2h soak | {{prod.soak2h}} |
| T+24h soak | {{prod.soak24h}} |
