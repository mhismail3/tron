# Settings model

An index. The settings model is documented in:

- [gateway/admin README](../src/admin/README.md): owners, entry points,
  invariants, signals and verification.
- [Settings contract](settings-contract.md): foundations, layers, the generated
  key table, timing, change path, native review, outside changes, project writes, the
  Home profile and presentation.

The headings below keep this doc's section numbers and anchors resolving.

## Contents
Every former section is listed below with its new home.

## 1. Foundations
→ [Foundations](settings-contract.md#foundations)

### F1. Schema
→ [Foundations, F1](settings-contract.md#foundations)

### F2. Truth
→ [Foundations, F2](settings-contract.md#foundations)

### F3. Policy
→ [Foundations, F3](settings-contract.md#foundations)

### F4. Layers
→ [Foundations, F4](settings-contract.md#foundations)

### 1.5 What follows
→ [Foundations](settings-contract.md#foundations)

## 2. Primitives: the groups
→ [Keys](settings-contract.md#keys)

### 2.1 Harness groups
→ [Presentation (sections)](settings-contract.md#presentation)

### 2.2 Supply and non-harness sections
→ [Presentation (sections)](settings-contract.md#presentation)

### 2.3 Keys by primitive
→ [Keys (generated)](settings-contract.md#keys)

### 2.4 Features decompose into primitives
Dropped (design rationale); see #758.

### 2.5 Stress tests
Dropped (design rationale); see #758.

## 3. Layers and resolution
→ [Layers](settings-contract.md#layers)

### 3.1 Precedence and the resolver
→ [Layers](settings-contract.md#layers)

### 3.2 Stores
→ [Layers](settings-contract.md#layers)

### 3.3 Which layers a target has
→ [Layers](settings-contract.md#layers)

### 3.4 Timing
→ [Timing](settings-contract.md#timing)

### 3.5 Trust and an untrusted project's layer
→ [Layers (project root and trust)](settings-contract.md#layers)

### 3.6 Capability-constrained values
→ [Layers (instances)](settings-contract.md#layers)

## 4. The schema
→ [Keys](settings-contract.md#keys)

### 4.1 Fields
→ [Keys](settings-contract.md#keys)

### 4.2 Example entries (real keys)
→ [Keys (generated)](settings-contract.md#keys)

### 4.3 Implemented: the schema and the resolver
→ [admin README](../src/admin/README.md#owns)

### 4.4 What stays outside the schema
→ [Keys](settings-contract.md#keys)

## 5. Changes, the record and policy
→ [Change path](settings-contract.md#change-path)

### 5.1 One path for every actor
→ [Change path](settings-contract.md#change-path)

### 5.2 The request and the record
→ [Change path](settings-contract.md#change-path)

### 5.3 Undo and Apply again
→ [Change path](settings-contract.md#change-path)

### 5.3a Implemented: the change path
→ [Change path](settings-contract.md#change-path)

### 5.4 Native review
→ [Native review](settings-contract.md#native-review)

### 5.4c Home changes a running worker
→ [Native review](settings-contract.md#native-review)

### 5.5 Exact-content consent
→ [Native review](settings-contract.md#native-review)

### 5.6 Outside changes
→ [Outside changes](settings-contract.md#outside-changes)

### 5.6a Implemented: outside changes
→ [Outside changes](settings-contract.md#outside-changes)

### 5.7 Project writes
→ [Project writes](settings-contract.md#project-writes)

## 6. The Home Home recipe
→ [Home profile](settings-contract.md#home-profile)

### 6.1 What it is
→ [Home profile](settings-contract.md#home-profile)

### 6.2 Who it applies to
→ [Layers](settings-contract.md#layers)

### 6.3 Model fallback queues
→ [Home profile (model queues)](settings-contract.md#home-profile)

### 6.4 Learned-profile changes
→ [Home profile (learned-profile changes)](settings-contract.md#home-profile)

## 7. Presentation and the rendering contract
→ [Presentation](settings-contract.md#presentation)

### 7.1 Posture: calm by default, everything on demand
→ [Presentation](settings-contract.md#presentation)

### 7.2 Sections
→ [Presentation](settings-contract.md#presentation)

### 7.3 Badges
→ [Presentation](settings-contract.md#presentation)

### 7.4 The Changes feed
→ [Presentation](settings-contract.md#presentation)

### 7.5 The rendering contract
→ [Presentation](settings-contract.md#presentation)

### 7.5a Implemented: the renderer contract
→ [Presentation](settings-contract.md#presentation)

### 7.6 Hand-built screens
→ [Presentation](settings-contract.md#presentation)

### 7.7 Surfaces
→ [Presentation](settings-contract.md#presentation)

### 7.8 Stress tests for rendering
Dropped (design rationale); see #758.

### 7.9 Each duplicate resolved to one editor
Dropped (design rationale); see #758.

## 8. Decisions and open questions
Numbered decisions are folded into the contract; their record is #758.

### 8.1 Decisions
Where the decisions cited from code and docs now live:
F1–F4 → [Foundations](settings-contract.md#foundations);
Native consent and 24-hour unanswered-card expiry → [Native review](settings-contract.md#native-review);
12 → [Change path](settings-contract.md#change-path) (record kept forever);
13, Q25 → [Outside changes](settings-contract.md#outside-changes);
14, Q24–Q27, 29 → [Project writes](settings-contract.md#project-writes);
15 → [Timing](settings-contract.md#timing); 34 → [Keys](settings-contract.md#keys) (`writers`).

### 8.2 Open questions
None.
