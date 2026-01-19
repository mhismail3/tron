/**
 * @fileoverview UI Component Types for RenderAppUI
 *
 * Defines the TypeScript types for the component tree structure
 * that the agent uses to create native iOS UI interfaces.
 *
 * The component structure follows the pattern:
 * { $tag: 'ComponentName', $props?: {...}, $children?: [...] | 'string' }
 */

// =============================================================================
// Base Types
// =============================================================================

/**
 * Base interface for all UI components.
 * Uses $ prefix to distinguish schema fields from props.
 */
export interface UIComponent {
  /** Component type identifier */
  $tag: UIComponentTag;
  /** Component-specific properties */
  $props?: Record<string, unknown>;
  /** Child components or text content */
  $children?: UIComponent[] | string;
}

// =============================================================================
// Component Tags
// =============================================================================

/** Layout component tags */
export type LayoutTag = 'VStack' | 'HStack' | 'ZStack' | 'ScrollView' | 'Spacer' | 'Divider';

/** Content component tags */
export type ContentTag = 'Text' | 'Icon' | 'Image';

/** Interactive component tags */
export type InteractiveTag = 'Button' | 'Toggle' | 'Slider' | 'TextField' | 'Picker';

/** Data display component tags */
export type DataTag = 'List' | 'ProgressView' | 'Badge';

/** Structural component tags */
export type StructuralTag = 'Section' | 'Card';

/** All valid component tags */
export type UIComponentTag = LayoutTag | ContentTag | InteractiveTag | DataTag | StructuralTag;

// =============================================================================
// Layout Component Props
// =============================================================================

export interface VStackProps {
  /** Spacing between children (default: 8) */
  spacing?: number;
  /** Horizontal alignment: leading, center, trailing */
  alignment?: 'leading' | 'center' | 'trailing';
}

export interface HStackProps {
  /** Spacing between children (default: 8) */
  spacing?: number;
  /** Vertical alignment: top, center, bottom */
  alignment?: 'top' | 'center' | 'bottom';
}

export interface ZStackProps {
  /** Alignment within the ZStack */
  alignment?: 'center' | 'top' | 'bottom' | 'leading' | 'trailing' | 'topLeading' | 'topTrailing' | 'bottomLeading' | 'bottomTrailing';
}

export interface ScrollViewProps {
  /** Scroll axis: vertical (default), horizontal, or both */
  axis?: 'vertical' | 'horizontal' | 'both';
}

export interface SpacerProps {
  /** Minimum length in points */
  minLength?: number;
}

// =============================================================================
// Content Component Props
// =============================================================================

export interface TextProps {
  /** Text style: body (default), title, headline, subheadline, caption, footnote, largeTitle */
  style?: 'body' | 'title' | 'headline' | 'subheadline' | 'caption' | 'footnote' | 'largeTitle' | 'title2' | 'title3';
  /** Font weight: regular, medium, semibold, bold */
  weight?: 'regular' | 'medium' | 'semibold' | 'bold';
  /** Text color (hex or semantic name) */
  color?: string;
  /** Maximum number of lines (0 for unlimited) */
  lineLimit?: number;
}

export interface IconProps {
  /** SF Symbol name */
  name: string;
  /** Icon size in points (default: 24) */
  size?: number;
  /** Icon color (hex or semantic name) */
  color?: string;
}

export interface ImageProps {
  /** SF Symbol name (mutually exclusive with data) */
  systemName?: string;
  /** Base64 encoded image data (mutually exclusive with systemName) */
  data?: string;
  /** Image width in points */
  width?: number;
  /** Image height in points */
  height?: number;
  /** Content mode: fit (default), fill */
  contentMode?: 'fit' | 'fill';
}

// =============================================================================
// Interactive Component Props
// =============================================================================

export interface ButtonProps {
  /** Button label text */
  label: string;
  /** Action identifier (returned to agent on tap) */
  actionId: string;
  /** Button style: primary (default), secondary, destructive, link */
  style?: 'primary' | 'secondary' | 'destructive' | 'link';
  /** Whether button is disabled */
  disabled?: boolean;
  /** SF Symbol icon name (optional) */
  icon?: string;
}

export interface ToggleProps {
  /** Toggle label text */
  label: string;
  /** Binding identifier (for state updates) */
  bindingId: string;
  /** Current value (default: false) */
  isOn?: boolean;
}

export interface SliderProps {
  /** Binding identifier (for state updates) */
  bindingId: string;
  /** Current value */
  value?: number;
  /** Minimum value (default: 0) */
  min?: number;
  /** Maximum value (default: 100) */
  max?: number;
  /** Step increment (default: 1) */
  step?: number;
  /** Label text (optional) */
  label?: string;
  /** Whether to show value (default: true) */
  showValue?: boolean;
}

export interface TextFieldProps {
  /** Binding identifier (for state updates) */
  bindingId: string;
  /** Placeholder text */
  placeholder?: string;
  /** Current value */
  value?: string;
  /** Label text (optional, shown above field) */
  label?: string;
  /** Whether this is a secure/password field */
  isSecure?: boolean;
  /** Keyboard type: default, email, number, phone, url */
  keyboardType?: 'default' | 'email' | 'number' | 'phone' | 'url';
}

export interface PickerProps {
  /** Binding identifier (for state updates) */
  bindingId: string;
  /** Available options */
  options: Array<{ label: string; value: string }>;
  /** Currently selected value */
  selected?: string;
  /** Label text (optional) */
  label?: string;
  /** Picker style: menu (default), wheel, segmented */
  style?: 'menu' | 'wheel' | 'segmented';
}

// =============================================================================
// Data Display Component Props
// =============================================================================

export interface ListProps {
  /** Array of items to display */
  items: unknown[];
  /** Template component for each item (uses $item placeholder in children) */
  itemKey?: string;
}

export interface ProgressViewProps {
  /** Progress value (0.0 to 1.0, or undefined for indeterminate) */
  value?: number;
  /** Label text (optional) */
  label?: string;
  /** Style: linear (default), circular */
  style?: 'linear' | 'circular';
  /** Tint color (hex or semantic name) */
  tint?: string;
}

export interface BadgeProps {
  /** Badge text */
  text: string;
  /** Background color (hex or semantic name) */
  color?: string;
}

// =============================================================================
// Structural Component Props
// =============================================================================

export interface SectionProps {
  /** Section header text */
  header?: string;
  /** Section footer text */
  footer?: string;
}

export interface CardProps {
  /** Card padding in points (default: 16) */
  padding?: number;
  /** Background style: filled (default), outlined */
  style?: 'filled' | 'outlined';
}

// =============================================================================
// Union Types for Typed Components
// =============================================================================

/** VStack component */
export interface VStackComponent {
  $tag: 'VStack';
  $props?: VStackProps;
  $children?: UIComponent[];
}

/** HStack component */
export interface HStackComponent {
  $tag: 'HStack';
  $props?: HStackProps;
  $children?: UIComponent[];
}

/** ZStack component */
export interface ZStackComponent {
  $tag: 'ZStack';
  $props?: ZStackProps;
  $children?: UIComponent[];
}

/** ScrollView component */
export interface ScrollViewComponent {
  $tag: 'ScrollView';
  $props?: ScrollViewProps;
  $children?: UIComponent[];
}

/** Spacer component */
export interface SpacerComponent {
  $tag: 'Spacer';
  $props?: SpacerProps;
}

/** Divider component */
export interface DividerComponent {
  $tag: 'Divider';
}

/** Text component */
export interface TextComponent {
  $tag: 'Text';
  $props?: TextProps;
  $children?: string;
}

/** Icon component */
export interface IconComponent {
  $tag: 'Icon';
  $props: IconProps;
}

/** Image component */
export interface ImageComponent {
  $tag: 'Image';
  $props: ImageProps;
}

/** Button component */
export interface ButtonComponent {
  $tag: 'Button';
  $props: ButtonProps;
}

/** Toggle component */
export interface ToggleComponent {
  $tag: 'Toggle';
  $props: ToggleProps;
}

/** Slider component */
export interface SliderComponent {
  $tag: 'Slider';
  $props: SliderProps;
}

/** TextField component */
export interface TextFieldComponent {
  $tag: 'TextField';
  $props: TextFieldProps;
}

/** Picker component */
export interface PickerComponent {
  $tag: 'Picker';
  $props: PickerProps;
}

/** List component */
export interface ListComponent {
  $tag: 'List';
  $props: ListProps;
  $children?: UIComponent;
}

/** ProgressView component */
export interface ProgressViewComponent {
  $tag: 'ProgressView';
  $props?: ProgressViewProps;
}

/** Badge component */
export interface BadgeComponent {
  $tag: 'Badge';
  $props: BadgeProps;
}

/** Section component */
export interface SectionComponent {
  $tag: 'Section';
  $props?: SectionProps;
  $children?: UIComponent[];
}

/** Card component */
export interface CardComponent {
  $tag: 'Card';
  $props?: CardProps;
  $children?: UIComponent[];
}

// =============================================================================
// RenderAppUI Parameters
// =============================================================================

/**
 * Parameters for the RenderAppUI tool
 */
export interface RenderAppUIParams {
  /** Unique canvas identifier for updates */
  canvasId: string;
  /** Optional sheet title (shown in toolbar) */
  title?: string;
  /** Root UI component tree */
  ui: UIComponent;
  /** Initial state bindings for interactive components */
  state?: Record<string, unknown>;
}

/**
 * User action from a button tap
 */
export interface UIActionResult {
  /** Canvas that generated the action */
  canvasId: string;
  /** Action identifier from the button */
  actionId: string;
  /** Timestamp of the action */
  timestamp: string;
}

/**
 * State change from an interactive component
 */
export interface UIStateChangeResult {
  /** Canvas that generated the change */
  canvasId: string;
  /** Binding identifier from the component */
  bindingId: string;
  /** New value */
  value: unknown;
  /** Timestamp of the change */
  timestamp: string;
}
