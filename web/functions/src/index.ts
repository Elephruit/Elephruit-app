/// Composition root for the BYOK backend. Two timing rules shape this file:
/// module load happens during DISCOVERY (emulator analysis and deploys),
/// which does not carry user env files — so nothing here may construct a
/// dependency eagerly; and onInit runs at real runtime startup, where env is
/// present — so that is where the production invariants live. The onCall
/// wrappers only authenticate, delegate to plain handlers, and translate
/// failures into the public error vocabulary.

import { randomUUID } from 'node:crypto'
import { initializeApp } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { onInit, setGlobalOptions } from 'firebase-functions/v2'
import { HttpsError, onCall, type CallableRequest } from 'firebase-functions/v2/https'
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
import { handleStreamAiResponse, STREAM_LEASE_TTL_SECONDS, type GatewayDeps } from './gateway/streamAiResponse.js'
import { FirestoreStreamLeases } from './limits/leases.js'
import { FirestoreRateLimiter } from './limits/rateLimiter.js'
import { PublicError, toHttpsError } from './log/errors.js'
import { createLogger } from './log/logger.js'
import { buildAdapterRegistry } from './providers/registry.js'
import { buildKeyVerifier } from './providers/verify.js'
import { handleListTaxonomyGaps, handleReportTaxonomyGaps } from './taxonomy/handlers.js'
import { FirestoreTaxonomyGapStore } from './taxonomy/store.js'
import { isDeveloperAdminClaims } from './taxonomy/admin.js'

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

function requireDeveloperAdmin(request: CallableRequest<unknown>): void {
  if (!isDeveloperAdminClaims(request.auth?.token, isEmulatorManifest)) {
    throw new HttpsError('permission-denied', 'Developer access is required.')
  }
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

export const reportAiTaxonomyGaps = onCall(credentialCallableOptions, async (request) => {
  requireUid(request)
  getDeps()
  return handleReportTaxonomyGaps(new FirestoreTaxonomyGapStore(getFirestore()), request.data)
})

export const listAiTaxonomyGaps = onCall(credentialCallableOptions, async (request) => {
  requireDeveloperAdmin(request)
  getDeps()
  return handleListTaxonomyGaps(new FirestoreTaxonomyGapStore(getFirestore()))
})

let cachedGatewayDeps: GatewayDeps | null = null
function getGatewayDeps(): GatewayDeps {
  if (cachedGatewayDeps) return cachedGatewayDeps
  const base = getDeps()
  const config = readConfig()
  const db = getFirestore()
  cachedGatewayDeps = {
    store: base.store,
    encryption: base.encryption,
    adapters: buildAdapterRegistry(config),
    rateLimiter: base.rateLimiter,
    leases: new FirestoreStreamLeases(db),
    audit: base.audit,
    log: base.log,
    now: base.now,
    newRequestId: base.newRequestId,
    sampleUsedEvent: () => Math.random() < 0.05,
  }
  return cachedGatewayDeps
}

/// Streaming holds an instance for the life of the generation; maxInstances
/// bounds what a runaway client can cost, and the lease TTL (which must
/// outlive timeoutSeconds) frees slots that crashed without a finally.
export const streamAiResponse = onCall(
  {
    enforceAppCheck: !isEmulatorManifest,
    timeoutSeconds: STREAM_LEASE_TTL_SECONDS - 30,
    maxInstances: 10,
    concurrency: 20,
    memory: '256MiB',
  },
  async (request, response) => {
    const uid = requireUid(request)
    const deps = getGatewayDeps()
    const sink = {
      sendChunk: async (chunk: unknown) => (response ? response.sendChunk(chunk) : false),
      signal: response?.signal ?? new AbortController().signal,
    }
    try {
      return await handleStreamAiResponse(deps, uid, request.data, sink)
    } catch (error) {
      const httpsError = toHttpsError(error)
      const details = httpsError.details as { code?: string } | undefined
      deps.log.warn('stream', {
        uid,
        status: 'error',
        normalizedErrorCode: details?.code ?? 'INTERNAL',
        ...(error instanceof PublicError && error.providerStatus !== undefined
          ? { providerStatus: error.providerStatus }
          : {}),
        ...(error instanceof PublicError && error.providerNote ? { providerNote: error.providerNote } : {}),
      })
      throw httpsError
    }
  },
)
