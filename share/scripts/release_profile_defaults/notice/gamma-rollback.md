Production release {{release.version}} ({{release.platform}}) failed a GAMMA test and has been rolled back.

Release: {{release.id}}
What failed: {{rollback.summary}}
Production is back on: {{rollback.sha}}
{{#if cr.id}}
Change Request {{cr.id}} is on hold. It will be closed as superseded by a new Change Request.
{{/if}}
The fix will ship under a new Change Request.
{{#if links.testingLog}}

Testing detail: {{links.testingLog}}
{{/if}}
