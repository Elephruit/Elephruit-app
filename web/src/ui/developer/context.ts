import { createContext, useContext } from 'react'

export const DeveloperAdminContext = createContext(false)

export function useDeveloperAdmin(): boolean {
  return useContext(DeveloperAdminContext)
}
