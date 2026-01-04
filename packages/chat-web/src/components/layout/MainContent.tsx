/**
 * @fileoverview MainContent Component
 *
 * Main content area wrapper with header, body, and footer sections.
 */

import type { ReactNode } from 'react';
import './MainContent.css';

// =============================================================================
// Types
// =============================================================================

export interface MainContentProps {
  /** Main content */
  children: ReactNode;
  /** Optional header content */
  header?: ReactNode;
  /** Optional footer content */
  footer?: ReactNode;
  /** Allow full width content (no max-width constraint) */
  fullWidth?: boolean;
  /** Remove padding from body */
  noPadding?: boolean;
  /** Additional class name */
  className?: string;
}

// =============================================================================
// Component
// =============================================================================

export function MainContent({
  children,
  header,
  footer,
  fullWidth = false,
  noPadding = false,
  className = '',
}: MainContentProps) {
  const bodyClasses = [
    'main-content-body',
    'scrollable',
    !fullWidth && 'constrained',
    noPadding && 'no-padding',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div className={`main-content ${className}`.trim()}>
      {header && <div className="main-content-header">{header}</div>}

      <div className={bodyClasses}>{children}</div>

      {footer && <div className="main-content-footer">{footer}</div>}
    </div>
  );
}
