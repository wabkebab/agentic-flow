# Agentic-flow roadmap

The open queue for the scaffold. [Roadmap history](docs/done/product-roadmap-history.md)
records earlier work and decisions. [Current plans](docs/README.md) are tracked in the
docs index.

## Before 1.0

- **2.6 Require CI on `main`.** Complete the Phase 4 publication scan,
  publish after the owner accepts the findings, then add a `main` ruleset with
  **CI gate** as the single required check. [Publication preparation](docs/done/feature-gate-and-handoff-fixes.md)
- **3.2 Validate an upgrade with a real adopter.** Record a version-to-version migration
  through the upgrade tool as evidence for the compatibility promise. [Upgrade plan](docs/done/feature-upgrade-surface.md)

## Follow-ups

- **2.3 Reflect GitHub issue state in document trackers.** Start with a preview of which
  checkboxes would change. Keep evidence-based lifecycle qualification in
  `scripts/lifecycle-status.sh`.
- **3.1 Revisit accepted risks.** Reconsider F-4 after its contract-drift trigger and
  decide how future revisit conditions should be tracked. [Accepted risks](docs/accepted_risks.md)
- **3.4 Make the remaining role contracts vendor-neutral.** Plan the contract routing and
  label migration alongside the role-signing follow-up. [Factory roadmap, R-22](docs/inprogress/product-harness-factory-optimization.md)
- **4.3 Derive roadmap status.** Decide which roadmap entries should link to executable
  checks or close-out evidence.
