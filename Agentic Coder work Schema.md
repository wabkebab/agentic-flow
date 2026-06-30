Agentic Coder work Schema

docs/
- done
- done/security
- in progress
- backlog
- templates
accepted_risk.md
General Documentation

Tree types of files

Security
Features
Product Analysis

Claude makes a plan of a security review of feature adding, and creates an implementation plan. Then using the skill plan-to-issues, it creates the issues at github Project.

Codex implements the issues, claude reviews and correct them. If they are done, Claude marks them as done, updates the github tracker and the document.

When the document is done, or user have accepted the risks ( in the security documents ) or not to implement the featues ( in the features document ). It is moved to /docs/done or docs/done/security.

There is a list of accepted_risks.md at docs/

Commit 

Claude commits with git-claude
Codex commits with git-codex

The commits 

When a plan is made then the skill plan-to-issues is made.

The workflow is the following, there is a review or plan, and it produces a security or feature document by Claude. With this document also a twin document for the implementation is made. This document doesn't have the actual code implementantion, but the insights for codex for a precise implementation.

The implementation is translated to tickets using the plan-to-issues skill. Codex gets the issues from github and implements them.

Claude reviews the implementation commits and -depends - ask Codex or Claude itself fixes the bugs and inconsistences and closes the issue.

 

