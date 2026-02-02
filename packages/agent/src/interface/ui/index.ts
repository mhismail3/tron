/**
 * @fileoverview UI Module Exports
 *
 * Exports all UI component types, schema, and validators
 * for the RenderAppUI tool.
 */

// Component types
export type {
  UIComponent,
  UIComponentTag,
  LayoutTag,
  ContentTag,
  InteractiveTag,
  DataTag,
  StructuralTag,
  // Layout props
  VStackProps,
  HStackProps,
  ZStackProps,
  ScrollViewProps,
  SpacerProps,
  // Content props
  TextProps,
  IconProps,
  ImageProps,
  // Interactive props
  ButtonProps,
  ToggleProps,
  SliderProps,
  TextFieldProps,
  PickerProps,
  // Data props
  ListProps,
  ProgressViewProps,
  BadgeProps,
  // Structural props
  SectionProps,
  CardProps,
  // Typed components
  VStackComponent,
  HStackComponent,
  ZStackComponent,
  ScrollViewComponent,
  SpacerComponent,
  DividerComponent,
  TextComponent,
  IconComponent,
  ImageComponent,
  ButtonComponent,
  ToggleComponent,
  SliderComponent,
  TextFieldComponent,
  PickerComponent,
  ListComponent,
  ProgressViewComponent,
  BadgeComponent,
  SectionComponent,
  CardComponent,
  // Tool params and results
  RenderAppUIParams,
  UIActionResult,
  UIStateChangeResult,
} from './components.js';

// Schema descriptions
export { UI_COMPONENT_SCHEMA, UI_COMPONENT_SCHEMA_CONDENSED } from './schema.js';

// Validators
export {
  validateUIComponent,
  validateRenderAppUIParams,
  type UIValidationResult,
} from './validators.js';
