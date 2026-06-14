// Extends Vitest's `expect` with the jest-dom matchers (toBeInTheDocument, etc.).
import '@testing-library/jest-dom/vitest'

// This project runs Vitest WITHOUT `globals: true` (a deliberate choice -- tests
// import { describe, it, expect } from 'vitest', and it keeps ArchUnitTS's root
// import from throwing; see architecture.archunit.ts). RTL's auto-cleanup needs
// globals, so register it explicitly here. A double-cleanup is a no-op, so tests
// with their own afterEach(cleanup) are unaffected.
import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/react'
afterEach(() => { cleanup() })

// Add project-specific test-environment shims below. Common ones:
//   - vi.stubEnv('VITE_SOME_FLAG', 'false')  // pin dev-only flags off under test
//   - jsdom <dialog> imperative-API stubs (showModal/close throw in jsdom)
