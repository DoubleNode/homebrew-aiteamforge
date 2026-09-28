# [{{release.dateMMMDDYYYY}}] {{release.releaseType}}: {{release.platform}} {{release.briefTitle}}

**Change Request**

| Subject: | {{release.releaseType}}: {{release.briefTitle}} |
| --- | --- |
| Description: | {{content.descriptionOutcomes}} |
| Anticipated Date/Time of change: | {{release.scheduledDate}} {{release.scheduledTime}} |
| Reason for change: | {{content.reasonForChange}} |
| Testing Documentation/Test details: | {{content.testingNarrative}} Full test detail: {{links.testingLog}} |
| Implementation Plan: | {{content.implementationPlan}} |
| Rollback Plan: | {{content.rollbackPlanText}} |

{{#if release.foldedItemCount}}
This release also includes behind-the-scenes maintenance with no visible change for users.
{{/if}}
