# Model and reasoning selector groundwork

Status: research and planning only. No production UI has been changed in this slice.

Branch: `codex/model-reasoning-sheet-groundwork`

## Product direction

Replace the existing separate `Menu` controls for Model and Thinking in the
Manage Session configuration section with one focused, native SwiftUI sheet:

- opens at a medium detent;
- presents available models as horizontally swipeable cards;
- gives each card a distinctive, lightweight 3D-looking icon that responds to
  horizontal motion with restrained translation, rotation, and a simulated
  specular highlight;
- presents the active model's reasoning choices below as a large discrete
  slider with visible breakpoints and semantic labels;
- remains usable with VoiceOver, Dynamic Type, Reduce Motion, Increase Contrast,
  compact height, and without relying on swipe-only interaction.

The first implementation target should be an existing session from
`SessionContextSheet`. New-session setup and onboarding use different state
flows and should be brought over only after the existing-session contract is
stable.

## Repository findings

### Current UI seam


[201 more lines in file. Use offset=31 to continue.]