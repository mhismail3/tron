# Self-Extending Local Product Notes

These notes summarize the completed productization scorecard campaign.
This is not a release, deploy, push, merge, notarization, or rollout checklist.

## Product Shape

Tron is productized as a local, chat-led self-extending agent environment. The
main flow is chat-led self-extension: a user can approve a
workspace-local grant, watch capability chips, inspect evidence, and let Tron
create, repair, test, and clean up local capabilities or packs.

The main vocabulary is capabilities and packs. Engine terms stay in Inspect.
The app renders server-owned generated UI, trust labels, model routing, and
action summaries rather than owning product truth locally.

## Scorecard Notes

- TPROD-A established the master scorecard, evidence manifest, product
  contracts, and explicit out-of-scope boundaries.
- TPROD-B added the managed `self-extend` skill and proved it fetches live
  `worker::protocol_guide` instead of copying protocol details.
- TPROD-C proved chat-led workspace autonomy, helper creation, repair,
  invocation, visual labels, and cleanup through a live session.
- TPROD-D added Created by Agent projection/history for created, updated,
  repaired, tested, failed, promoted, revoked, discarded, and reused work.
- TPROD-E completed local pack lifecycle operations and generated Pack surfaces
  for register, inspect, configure, activate, disable, rollback, revoke, and
  remove.
- TPROD-F moved plain source/trust/promotion/revocation/cleanup presentation to
  server-owned trust labels backed by source evidence.
- TPROD-G completed generated UI authoring for native fixed-catalog surfaces,
  stored actions, validation state, preview/diff content, and Inspect details.
- TPROD-H added model presets, automation routing evidence, subagent task/model
  lineage, and iOS chip projection.
- TPROD-I proved the flagship Tron-maintains-Tron local work loop without
  publishing actions.
- TPROD-J shipped local example packs for Tron maintenance, everyday
  organization, and creative/knowledge workflows.

## User-Visible Changes

- Chat can be the primary self-extension surface.
- Created by Agent gives a durable place to revisit locally created helpers and
  packs.
- Pack rows use product language while Inspect keeps exact package, source,
  activation, trust, conformance, generated UI, and invocation details.
- Generated UI authoring lets new capability surfaces appear without app
  updates when they fit the stable native catalog.
- Model presets are Local when possible, Balanced, and Deep. Selected routes
  and fallbacks are visible after the server decides.

## Known boundaries

Local pack discovery is disk-only. Remote package discovery, remote marketplace
install, package publishing, production rollout, and release automation are not
part of this campaign.

TPROD-K added these docs. TPROD-L completed final hardening, visual QA, soak,
Mac/CLI smoke, static gates, docs drift checks, and closeout evidence for the
100/100 productization scorecard.
