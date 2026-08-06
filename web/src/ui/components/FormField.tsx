/// Label + control + one line underneath: help when things are fine, the error
/// when they aren't. Keeps validation display in one place instead of ad-hoc
/// alert paragraphs.

import type { ReactNode } from 'react'

export function FormField({
  label,
  htmlFor,
  help,
  error,
  children,
}: {
  label: ReactNode
  htmlFor?: string
  help?: ReactNode
  error?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="form-field">
      <label className="field-label" htmlFor={htmlFor}>
        {label}
      </label>
      {children}
      {error ? (
        <p className="field-error" role="alert">
          {error}
        </p>
      ) : help ? (
        <p className="field-help">{help}</p>
      ) : null}
    </div>
  )
}
