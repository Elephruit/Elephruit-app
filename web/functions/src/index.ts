/// Composition root for the BYOK backend. Two timing rules shape this file:
/// module load happens during DISCOVERY (emulator analysis and deploys),
/// which does not carry user env files — so nothing here may construct a
/// dependency eagerly; and onInit runs at real runtime startup, where env is
/// present — so that is where the production invariants live. The onCall
/// wrappers only authenticate, delegate to plain handlers, and translate
/// failures into the public error vocabulary. gatewayPing is the streaming
/// spike and dies when the real gateway lands.

import { randomUUID } from 'node:crypto'
import { initializeApp } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { onInit, setGlobalOptions } from 'firebase-functions/v2'
import { onCall, type CallableRequest } from 'firebase-functions/v2/https'
import { firestoreAuditWriter } from './audit/audit.js'
import { assertStartupInvariants, readConfig } from './config.js'
import {
  handleAddCredential,
  handleDeleteCredential,
  handleReplaceCredential,
  handleVerifyCredential,
  type CredentialDeps,
} from './credentials/handlers.js'
import { FirestoreCredentialStore } from './credentials/store.js'
import { buildEncryptionService } from './crypto/select.js'
import { FirestoreRateLimiter } from './limits/rateLimiter.js'
import { PublicError, toHttpsError } from './log/errors.js'
import { createLogger } from './log/logger.js'
import { buildKeyVerifier } from './providers/verify.js'

setGlobalOptions({ region: 'us-central1' })

onInit(() => {
  assertStartupInvariants(readConfig())
})

let cachedDeps: CredentialDeps | null = null
function getDeps(): CredentialDeps {
  if (cachedDeps) return cachedDeps
  const config = readConfig()
  assertStartupInvariants(config)
  initializeApp()
  const db = getFirestore()
  cachedDeps = {
    store: new FirestoreCredentialStore(db),
    encryption: buildEncryptionService(config),
    verifyKey: buildKeyVerifier(config),
    rateLimiter: new FirestoreRateLimiter(db),
    audit: firestoreAuditWriter(db),
    log: createLogger(),
    now: () => new Date(),
    newId: () => randomUUID(),
    newRequestId: () => randomUUID(),
  }
  return cachedDeps
}

/// App Check cannot be verified under the emulator (there is no App Check
/// emulator); production always enforces — the startup invariants and the
/// cloud runbook hold that line. Evaluated at discovery, which carries
/// FUNCTIONS_EMULATOR only when emulating.
const isEmulatorManifest = readConfig().isEmulator
const credentialCallableOptions = {
  enforceAppCheck: !isEmulatorManifest,
  timeoutSeconds: 30,
  maxInstances: 5,
}

function requireUid(request: CallableRequest<unknown>): string {
  const uid = request.auth?.uid
  if (!uid) {
    throw toHttpsError(new PublicError('AUTH_REQUIRED', 'Sign in to manage AI credentials.'))
  }
  return uid
}

function credentialCallable<Result>(
  operation: string,
  handler: (deps: CredentialDeps, uid: string, input: unknown) => Promise<Result>,
) {
  return onCall(credentialCallableOptions, async (request) => {
    const uid = requireUid(request)
    const deps = getDeps()
    const startedAt = Date.now()
    try {
      const result = await handler(deps, uid, request.data)
      deps.log.info(operation, { uid, operation, durationMs: Date.now() - startedAt, status: 'ok' })
      return result
    } catch (error) {
      const httpsError = toHttpsError(error)
      const details = httpsError.details as { code?: string } | undefined
      deps.log.warn(operation, {
        uid,
        operation,
        durationMs: Date.now() - startedAt,
        status: 'error',
        normalizedErrorCode: details?.code ?? 'INTERNAL',
      })
      throw httpsError
    }
  })
}

export const addAiCredential = credentialCallable('credential_add', handleAddCredential)
export const verifyAiCredential = credentialCallable('credential_verify', handleVerifyCredential)
export const replaceAiCredential = credentialCallable('credential_replace', handleReplaceCredential)
export const deleteAiCredential = credentialCallable('credential_delete', handleDeleteCredential)

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

interface PingChunk {
  type: 'ping'
  index: number
  sentAt: number
}

export const gatewayPing = onCall<unknown, Promise<object>, PingChunk>(
  { enforceAppCheck: false },
  async (request, response) => {
    const spacingMs = 300
    for (let index = 0; index < 3; index += 1) {
      await response?.sendChunk({ type: 'ping', index, sentAt: Date.now() })
      await sleep(spacingMs)
    }
    return { done: true, chunks: 3, spacingMs, acceptsStreaming: request.acceptsStreaming }
  },
)
