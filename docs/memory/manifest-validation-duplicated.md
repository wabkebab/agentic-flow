---
id: manifest-validation-duplicated
type: trap
status: active
---
The five-column manifest retains `merge-policy` only for old upgrader compatibility.
Export and upgrade validate `preserve|force|none`, but do not apply per-file policy;
the chosen apply mode controls non-destructive and force behavior for every file.

**Why:** old installed upgraders still parse five columns and reject unknown policies.
Removing or repurposing the column would require a versioned migration for those parsers.

**How to apply:** keep the column and its legal values stable until a versioned old-upgrader
migration exists. Do not describe its values as executable per-file policy. Doctor now
validates through the shared payload library; the full export test exercises an adopter's doctor.
