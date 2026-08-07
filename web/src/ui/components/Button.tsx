/// Buttons as components, styled by the same classes the un-migrated screens
/// still use directly — the two coexist until every surface has moved over.
/// `loading` keeps the width and swaps the label for a spinner, so layouts
/// never jump while work is in flight.

import type { ButtonHTMLAttributes, ReactNode, Ref } from 'react'
import { Icon } from './Icon'

type Variant = 'primary' | 'secondary' | 'quiet' | 'ghost' | 'destructive'

const VARIANT_CLASS: Record<Variant, string> = {
  primary: 'button',
  secondary: 'button button-secondary',
  quiet: 'button button-quiet',
  ghost: 'button button-plain',
  destructive: 'button button-destructive',
}

export function Button({
  variant = 'secondary',
  small = false,
  loading = false,
  icon,
  children,
  disabled,
  type = 'button',
  className,
  buttonRef,
  ...rest
}: {
  variant?: Variant
  small?: boolean
  loading?: boolean
  icon?: string
  children: ReactNode
  buttonRef?: Ref<HTMLButtonElement>
} & ButtonHTMLAttributes<HTMLButtonElement>) {
  const classes = [VARIANT_CLASS[variant], small && 'button-small', className].filter(Boolean).join(' ')
  return (
    <button
      ref={buttonRef}
      type={type}
      className={classes}
      disabled={disabled || loading}
      data-loading={loading || undefined}
      {...rest}
    >
      {loading && <span className="button-spinner" aria-hidden="true" />}
      <span className="button-content">
        {icon && <Icon name={icon} size={small ? 14 : 16} />}
        {children}
      </span>
    </button>
  )
}

export function IconButton({
  label,
  icon,
  size = 16,
  className,
  type = 'button',
  ...rest
}: {
  label: string
  icon: string
  size?: number
} & ButtonHTMLAttributes<HTMLButtonElement>) {
  const classes = ['icon-button', className].filter(Boolean).join(' ')
  return (
    <button type={type} className={classes} aria-label={label} title={label} {...rest}>
      <Icon name={icon} size={size} />
    </button>
  )
}
