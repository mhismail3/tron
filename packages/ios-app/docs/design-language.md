# Tron mobile design language (Sandbox draft)

Status: a proposal prototyped only in Settings → Setup → Sandbox. Production surfaces keep
[presentation parity](presentation-parity.md) until a change adopts a part of this language there.
Inspired by a layout-and-motion study of quiet canvases, floating controls and liquid
transitions, but kept in Tron's identity: theme ink, Tron type and glass. Code:
`Sources/UI/Settings/Sandbox/` (`SandboxDesign`, `TronFluidSheet`, `Chat/`).

## Principles

1. **One focus per screen.** Position, size and grouping set the hierarchy before color or
   decoration. Persistent controls stay near the thumb, and content scrolls under them.
2. **Quiet canvas, selective color.** Neutral surfaces and ink. `tronPrimary` marks the user's
   own content, selection and the primary action. Semantic hues mark status only.
3. **Glass is for controls, not content.** Liquid Glass belongs to floating controls, sheets and
   menus. Reading surfaces, such as messages and rows, sit on solid or washed fills. Glass is
   never stacked on glass.
4. **Motion explains a relationship.** It shows where a surface came from, what stays active and
   how one state became the next. Nothing moves only to decorate a data refresh.
5. **Everything is interruptible.** Each transition is driven by one value and can be reversed
   from where it is drawn.

## Tokens

| Token | Value | Rule |
|---|---|---|
| Outer inset | 16 | Titles, panels and row content share one inset |
| Spacing | 4, 8, 12, 16, 24, 32 | Tight within a group, wide between purposes |
| Corners | circle; capsule = height/2; card 16; panel 28; sheet concentric with the display, minimum 34 | Continuous corners; nested shapes are concentric |
| Hairline | 0.5 pt, ink at 8%, or the accent at 22% on a tinted card | Separates rows; never a box around every row |
| Shadow | none on glass; 6% black, y 4, blur 16 on solid floating fills | Just enough to show the layer |
| Hit area | ≥ 44 × 44 | Visible circles may be 32–44; the hit region is separate |
| Bottom clearance | the control row's real height + 12 | Applied as a scroll inset, never as a guessed constant |

Type uses Tron's family through `TronTypography`; every role scales with Dynamic Type.

| Role | Size / weight | Use |
|---|---|---|
| Screen title | 16 semibold | Header context; never a large bold title on every surface |
| Focal | 22–32 semibold | One value or statement per screen |
| Body | 15 regular | Messages and the composer |
| Row primary / secondary | 14 semibold / 11.5 regular | Two-line rows and chips |
| Utility | 10–12 semibold | Badges, counts, timestamps; tabular figures for changing numbers |

Color roles: canvas `tronBackground` with grain; solid surface `tronSurfaceElevated`; ink
`tronTextPrimary`, `tronTextSecondary` and `tronTextMuted`. `tronPrimary` fills the user's own
message and the primary action circle. Tool families keep their existing identities (read,
edit, shell, web) as small glyph tints only. Success, warning and error are text and glyph
colors, not fills.

## Components

Each component defines its slots, bounds, hit region, states and motion.

- **Action circle.** A glyph on a glass circle (36–44) inside a 44 hit region. States: idle,
  pressed (scale 0.94, 100 ms), expanded (its glyph turns into close), disabled (muted
  ink). Its center is an animation origin. The glyph keeps its size at large text sizes
  and offers the Large Content Viewer instead.
- **Capsule.** A bounded group on glass, such as the header context picker or the composer. A
  pressed capsule highlights its whole surface.
- **Context picker.** A two-line label (title, secondary) with a chevron. It opens an inset
  panel, and the current choice stays visible in the parent.
- **Message.** The user's message is a primary-filled bubble at the trailing edge, radius 20.
  The assistant's message is text on the canvas at the leading edge, with a small mark.
- **Tool chip.** A capsule with a family glyph, a one-line label and a status glyph. A run of
  chips collapses to a single "n tools" chip, which expands in place.
- **Feedback capsule → badge cluster.** One status object in two forms: readable text, then
  overlapping badges (at most 3, then a count) at the same trailing anchor. It opens a detail
  sheet. Its accessible name states the count and the purpose.
- **Grouped row.** A leading glyph, two-line labels and a trailing value. The whole row is the
  target.

## Motion vocabulary

One spring family: critically damped, starting at the current presented value with the
current velocity. Bounce, 0.12–0.15, appears only after a flick.

| Motion | Driver | Values |
|---|---|---|
| Press | state | 100 ms ease-out, scale 0.94–0.97 |
| Content swap | state | 150 ms cross-fade, plus a 6 pt rise for arriving labels |
| Geometry (resize, reflow, chips) | spring | response 0.34 |
| Sheet travel | spring | response 0.42; release carries the finger's velocity |
| Menu or collapse | one progress p ∈ [0,1] on a spring | response 0.36; labels from p > 0.25 |
| Gesture | direct | 1:1 with the finger; rubber-band past the bounds |

Rules:

- **One progress value per transition.** Geometry, opacity, the wash, hit testing and the
  accessibility state are all derived from that value. Nothing visually closed can take a tap.
- **Reversal.** A second tap retargets the same value, never restarting from an end. A release
  projects momentum, then settles toward the nearer rest.
- **Leading movement.** The container moves first and its content follows. Labels arrive late
  and leave early.
- **Reduce Motion.** Travel and separation become 200 ms cross-fades with the same states and
  the same order.

## Presentations

| Type | Bounds | Backdrop | Dismissal | Use |
|---|---|---|---|---|
| Inset panel | 8 pt from the sides, anchored at its source, content height; scale 0.96 → 1 with a 16 pt travel | dim 0.18 | backdrop tap, close action, escape | One compact sub-choice |
| Sheet (`TronFluidSheet`) | Bottom-floating, content height, capped below the status bar | dim 0.22 (light) / 0.42 (dark), tracking progress | drag, fling, backdrop tap, Done, escape | Lists and details |
| Focus | Full height below the status bar, with its own header and actions | dim 0.42 | Done or drag from the header; no backdrop tap | Deep editing or review |

Every presentation keeps its parent mounted, including its scroll position, draft and
selection. It owns all input while open; the parent is hidden from accessibility. Dismissal
returns VoiceOver focus to the control that opened it. Nested presentations stack, and only
the top one takes input.

## State owners

Each concern has one owner:

- navigation and return context;
- overlay: kind, source and dismissal;
- draft: composer text and attachments, which survive the keyboard and overlays;
- feedback: events, which are independent of their compact form;
- motion: menu progress and sheet position.

Semantic state never comes from a motion completion, so an interrupted animation, a skipped
frame or Reduce Motion cannot change the logical outcome.
