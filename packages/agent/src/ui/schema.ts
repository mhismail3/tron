/**
 * @fileoverview UI Schema Description for RenderAppUI
 *
 * Contains the schema documentation that gets embedded in the
 * RenderAppUI tool description for the LLM.
 */

/**
 * Full schema description for the RenderAppUI tool.
 * This is embedded in the tool description so the LLM knows
 * how to construct valid UI component trees.
 */
export const UI_COMPONENT_SCHEMA = `
## Component Schema

Components use a recursive JSON structure:
\`\`\`json
{
  "$tag": "ComponentName",
  "$props": { ... },
  "$children": [ ... ] | "text content"
}
\`\`\`

### Layout Components

**VStack** - Vertical stack
- Props: spacing (number), alignment ("leading" | "center" | "trailing")
- Children: UIComponent[]

**HStack** - Horizontal stack
- Props: spacing (number), alignment ("top" | "center" | "bottom")
- Children: UIComponent[]

**ZStack** - Layered stack
- Props: alignment ("center" | "top" | "bottom" | "leading" | "trailing" | "topLeading" | "topTrailing" | "bottomLeading" | "bottomTrailing")
- Children: UIComponent[]

**ScrollView** - Scrollable container
- Props: axis ("vertical" | "horizontal" | "both")
- Children: UIComponent[]

**Spacer** - Flexible space
- Props: minLength (number)

**Divider** - Visual separator (no props)

### Content Components

**Text** - Text display
- Props: style ("body" | "title" | "headline" | "subheadline" | "caption" | "footnote" | "largeTitle" | "title2" | "title3"), weight ("regular" | "medium" | "semibold" | "bold"), color (string), lineLimit (number)
- Children: string (text content)

**Icon** - SF Symbol icon
- Props: name (string, required - SF Symbol name), size (number), color (string)

**Image** - Image display
- Props: systemName (string - SF Symbol) OR data (string - base64), width (number), height (number), contentMode ("fit" | "fill")

### Interactive Components

**Button** - Tappable button
- Props: label (string, required), actionId (string, required - returned on tap), style ("primary" | "secondary" | "destructive" | "link"), disabled (boolean), icon (string - SF Symbol)

**Toggle** - Switch control
- Props: label (string, required), bindingId (string, required), isOn (boolean)

**Slider** - Value slider
- Props: bindingId (string, required), value (number), min (number), max (number), step (number), label (string), showValue (boolean)

**TextField** - Text input
- Props: bindingId (string, required), placeholder (string), value (string), label (string), isSecure (boolean), keyboardType ("default" | "email" | "number" | "phone" | "url")

**Picker** - Selection control
- Props: bindingId (string, required), options (array of {label, value}), selected (string), label (string), style ("menu" | "wheel" | "segmented")

### Data Display Components

**List** - List of items
- Props: items (array, required), itemKey (string)
- Children: UIComponent (template, use $item for data binding)

**ProgressView** - Progress indicator
- Props: value (number 0-1, omit for indeterminate), label (string), style ("linear" | "circular"), tint (string)

**Badge** - Badge/tag
- Props: text (string, required), color (string)

### Structural Components

**Section** - Grouped content with header
- Props: header (string), footer (string)
- Children: UIComponent[]

**Card** - Card container
- Props: padding (number), style ("filled" | "outlined")
- Children: UIComponent[]

## Colors

Use semantic names or hex values:
- Semantic: "primary", "secondary", "accent", "destructive", "success", "warning"
- Hex: "#FF5500", "#3B82F6"

## State Bindings

Interactive components use bindingId for two-way data binding:
1. Set initial values in the \`state\` parameter
2. User changes are sent back via UI state change events
3. Use bindingId to track which control changed

## Actions

Buttons use actionId to identify taps:
1. User taps button
2. Agent receives UI action event with actionId
3. Agent can respond to the action in next turn
`;

/**
 * Condensed schema for contexts where space is limited
 */
export const UI_COMPONENT_SCHEMA_CONDENSED = `
Components: { "$tag": "Name", "$props": {...}, "$children": [...] | "text" }

Layout: VStack, HStack, ZStack, ScrollView (children: UIComponent[]), Spacer, Divider
Content: Text (children: string), Icon (name: SF Symbol), Image (systemName or data)
Interactive: Button (label, actionId), Toggle (label, bindingId), Slider (bindingId, min, max), TextField (bindingId), Picker (bindingId, options)
Data: List (items, template child), ProgressView (value 0-1), Badge (text, color)
Structural: Section (header, children), Card (children)

actionId: Identifies button taps returned to agent
bindingId: Two-way binding for form controls
state: Initial values for bound controls
`;
