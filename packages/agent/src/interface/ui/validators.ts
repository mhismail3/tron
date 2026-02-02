/**
 * @fileoverview UI Component Validators
 *
 * Runtime validation for UI component trees before rendering.
 * Validates structure, required props, and type correctness.
 */

// =============================================================================
// Validation Result
// =============================================================================

export interface UIValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}

// =============================================================================
// Valid Tags
// =============================================================================

const LAYOUT_TAGS = new Set(['VStack', 'HStack', 'ZStack', 'ScrollView', 'Spacer', 'Divider']);
const CONTENT_TAGS = new Set(['Text', 'Icon', 'Image']);
const INTERACTIVE_TAGS = new Set(['Button', 'Toggle', 'Slider', 'TextField', 'Picker']);
const DATA_TAGS = new Set(['List', 'ProgressView', 'Badge']);
const STRUCTURAL_TAGS = new Set(['Section', 'Card']);

const ALL_TAGS = new Set([
  ...LAYOUT_TAGS,
  ...CONTENT_TAGS,
  ...INTERACTIVE_TAGS,
  ...DATA_TAGS,
  ...STRUCTURAL_TAGS,
]);

// =============================================================================
// Component-Specific Validators
// =============================================================================

function validateIconProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.name || typeof props.name !== 'string') {
    errors.push(`${path}: Icon requires 'name' prop (SF Symbol name)`);
  }
}

function validateButtonProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.label || typeof props.label !== 'string') {
    errors.push(`${path}: Button requires 'label' prop`);
  }
  if (!props?.actionId || typeof props.actionId !== 'string') {
    errors.push(`${path}: Button requires 'actionId' prop`);
  }
}

function validateToggleProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.label || typeof props.label !== 'string') {
    errors.push(`${path}: Toggle requires 'label' prop`);
  }
  if (!props?.bindingId || typeof props.bindingId !== 'string') {
    errors.push(`${path}: Toggle requires 'bindingId' prop`);
  }
}

function validateSliderProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.bindingId || typeof props.bindingId !== 'string') {
    errors.push(`${path}: Slider requires 'bindingId' prop`);
  }
}

function validateTextFieldProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.bindingId || typeof props.bindingId !== 'string') {
    errors.push(`${path}: TextField requires 'bindingId' prop`);
  }
}

function validatePickerProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.bindingId || typeof props.bindingId !== 'string') {
    errors.push(`${path}: Picker requires 'bindingId' prop`);
  }
  if (!props?.options || !Array.isArray(props.options)) {
    errors.push(`${path}: Picker requires 'options' prop (array)`);
  }
}

function validateListProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.items || !Array.isArray(props.items)) {
    errors.push(`${path}: List requires 'items' prop (array)`);
  }
}

function validateBadgeProps(props: Record<string, unknown> | undefined, path: string, errors: string[]): void {
  if (!props?.text || typeof props.text !== 'string') {
    errors.push(`${path}: Badge requires 'text' prop`);
  }
}

// =============================================================================
// Recursive Component Validator
// =============================================================================

function validateComponent(
  component: unknown,
  path: string,
  errors: string[],
  warnings: string[],
  depth: number
): void {
  // Safety limit for deep nesting
  if (depth > 50) {
    errors.push(`${path}: Component tree exceeds maximum depth of 50`);
    return;
  }

  // Must be an object
  if (typeof component !== 'object' || component === null) {
    errors.push(`${path}: Component must be an object`);
    return;
  }

  const comp = component as Record<string, unknown>;

  // Must have $tag
  if (!comp.$tag || typeof comp.$tag !== 'string') {
    errors.push(`${path}: Component must have a '$tag' string property`);
    return;
  }

  const tag = comp.$tag as string;

  // Tag must be valid
  if (!ALL_TAGS.has(tag)) {
    errors.push(`${path}: Unknown component tag '${tag}'`);
    return;
  }

  const props = comp.$props as Record<string, unknown> | undefined;
  const children = comp.$children;

  // Validate component-specific required props
  switch (tag) {
    case 'Icon':
      validateIconProps(props, path, errors);
      break;
    case 'Button':
      validateButtonProps(props, path, errors);
      break;
    case 'Toggle':
      validateToggleProps(props, path, errors);
      break;
    case 'Slider':
      validateSliderProps(props, path, errors);
      break;
    case 'TextField':
      validateTextFieldProps(props, path, errors);
      break;
    case 'Picker':
      validatePickerProps(props, path, errors);
      break;
    case 'List':
      validateListProps(props, path, errors);
      break;
    case 'Badge':
      validateBadgeProps(props, path, errors);
      break;
  }

  // Validate children based on component type
  if (children !== undefined) {
    // Text component expects string children
    if (tag === 'Text') {
      if (typeof children !== 'string') {
        errors.push(`${path}: Text component's $children must be a string`);
      }
    }
    // Components that shouldn't have children
    else if (tag === 'Spacer' || tag === 'Divider' || tag === 'Icon' || tag === 'Image' ||
             tag === 'Button' || tag === 'Toggle' || tag === 'Slider' || tag === 'TextField' ||
             tag === 'Picker' || tag === 'ProgressView' || tag === 'Badge') {
      warnings.push(`${path}: ${tag} component ignores $children`);
    }
    // List expects a single template child
    else if (tag === 'List') {
      if (typeof children === 'object' && !Array.isArray(children)) {
        validateComponent(children, `${path}.$children`, errors, warnings, depth + 1);
      } else if (Array.isArray(children) && children.length > 0) {
        validateComponent(children[0], `${path}.$children[0]`, errors, warnings, depth + 1);
        if (children.length > 1) {
          warnings.push(`${path}: List only uses the first child as template`);
        }
      }
    }
    // Container components expect array of children
    else if (Array.isArray(children)) {
      for (let i = 0; i < children.length; i++) {
        validateComponent(children[i], `${path}.$children[${i}]`, errors, warnings, depth + 1);
      }
    } else {
      errors.push(`${path}: ${tag} component's $children must be an array`);
    }
  }
}

// =============================================================================
// Main Validation Function
// =============================================================================

/**
 * Validate a UI component tree
 */
export function validateUIComponent(component: unknown): UIValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  validateComponent(component, 'ui', errors, warnings, 0);

  return {
    valid: errors.length === 0,
    errors,
    warnings,
  };
}

/**
 * Validate RenderAppUI parameters
 */
export function validateRenderAppUIParams(params: unknown): UIValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  if (typeof params !== 'object' || params === null) {
    return { valid: false, errors: ['Parameters must be an object'], warnings: [] };
  }

  const p = params as Record<string, unknown>;

  // Validate canvasId (optional, but if provided must be a string)
  if (p.canvasId !== undefined && typeof p.canvasId !== 'string') {
    errors.push('canvasId must be a string if provided');
  }

  // Validate title (optional)
  if (p.title !== undefined && typeof p.title !== 'string') {
    errors.push('title must be a string');
  }

  // Validate ui component tree
  if (!p.ui) {
    errors.push('ui component tree is required');
  } else {
    const uiResult = validateUIComponent(p.ui);
    errors.push(...uiResult.errors);
    warnings.push(...uiResult.warnings);
  }

  // Validate state (optional)
  if (p.state !== undefined && (typeof p.state !== 'object' || p.state === null)) {
    errors.push('state must be an object');
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
  };
}
