---
name: privy
description: Use when building wallet infrastructure, authentication systems, or
  financial applications. Reach for Privy when you need to create embedded
  wallets, authenticate users, manage wallet controls and policies, execute
  transactions across blockchains, or build treasury and agent wallet systems.
metadata:
  mintlify-proj: privy
  version: "1.0"
---

# Privy Skill Reference

## Product summary

Privy is a programmable wallet infrastructure platform that enables developers to build secure financial applications with embedded wallets, authentication, and transaction execution across 50+ blockchains (Ethereum, Solana, Tempo, Bitcoin, and others). Use Privy to authenticate users, create and manage embedded wallets, enforce spending policies, execute transactions, and build treasury or agent wallet systems.

**Key files and configuration:**
- **App ID and App Secret**: Found in Privy Dashboard > App settings > Basics tab. Required for all API calls.
- **PrivyProvider**: React/React Native wrapper component that initializes the SDK (requires `appId` and optional `clientId`)
- **REST API base**: `https://api.privy.io/v1/`
- **Webhook signing secret**: Used to verify incoming webhook payloads via Svix
- **Client SDKs**: React, React Native, Swift, Android, Flutter, Unity, NodeJS, Java, Go, Rust, Ruby, Python

**Primary docs**: https://docs.privy.io

## When to use

Reach for Privy when:
- Building consumer apps that need user authentication and embedded wallets
- Creating treasury or organization wallets with multi-sig controls
- Implementing AI agent wallets with scoped permissions and policies
- Executing transactions across multiple blockchains from a single interface
- Enforcing spending limits, transaction rules, or approval workflows
- Integrating fiat on/off-ramps, card spend, or yield protocols
- Managing user identity with multiple login methods (email, social, passkeys, wallet)
- Building server-side wallet automation or delegated signing
- Requiring multi-factor authentication or granular access controls

## Quick reference

### SDK initialization (React)

```tsx
import {PrivyProvider} from '@privy-io/react-auth';

<PrivyProvider
  appId="your-privy-app-id"
  clientId="your-app-client-id"
  config={{
    embeddedWallets: {
      ethereum: { createOnLogin: 'users-without-wallets' }
    }
  }}
>
  {children}
</PrivyProvider>
```

### REST API authentication

All REST API calls require:
- **Authorization header**: `Authorization: Basic base64(appId:appSecret)`
- **Privy App ID header**: `privy-app-id: your-privy-app-id`

### Common wallet operations

| Operation | SDK | REST Endpoint |
|-----------|-----|---------------|
| Create wallet | `useCreateWallet()` | `POST /v1/wallets` |
| Get wallet | `useWallets()` | `GET /v1/wallets/{id}` |
| Get wallet balance | `wallet.getBalance()` | `GET /v1/wallets/{id}/balance` |
| Send transaction | `wallet.sendTransaction()` | `POST /v1/wallets/{id}/ethereum/eth_sendTransaction` |
| Sign message | `wallet.signMessage()` | `POST /v1/wallets/{id}/ethereum/personal_sign` |
| List transactions | N/A | `GET /v1/wallets/{id}/transactions` |

### Common user operations

| Operation | SDK | REST Endpoint |
|-----------|-----|---------------|
| Get user | `usePrivy()` | `GET /v1/users/{id}` |
| Create user | N/A | `POST /v1/users` |
| Get user by email | N/A | `GET /v1/users/by_email_address/{email}` |
| Delete user | N/A | `DELETE /v1/users/{id}` |
| Freeze user | N/A | `POST /v1/users/{id}/freeze` |

### Policy and control operations

| Operation | REST Endpoint |
|-----------|---------------|
| Create policy | `POST /v1/policies` |
| Get policy | `GET /v1/policies/{id}` |
| Update policy | `PATCH /v1/policies/{id}` |
| Create key quorum | `POST /v1/key-quorums` |
| Get key quorum | `GET /v1/key-quorums/{id}` |

### Webhook events to subscribe to

- `user.created` — User account created
- `user.authenticated` — User logged in
- `wallet.funds_deposited` — Funds received
- `wallet.funds_withdrawn` — Funds sent
- `transaction.confirmed` — Transaction confirmed onchain
- `transaction.failed` — Transaction failed
- `wallet_action.transfer.succeeded` — Transfer completed
- `wallet_action.swap.succeeded` — Swap completed
- `wallet_action.earn_deposit.succeeded` — Yield deposit completed

## Decision guidance

### When to use embedded wallets vs external wallets

| Scenario | Use embedded | Use external |
|----------|-------------|-------------|
| New users, consumer app | ✓ | |
| Users with existing wallets | | ✓ |
| Self-custodial requirement | ✓ | ✓ |
| Server-controlled wallets | ✓ | |
| Power users, crypto-native | | ✓ |
| Seamless onboarding | ✓ | |

### When to use different wallet ownership models

| Model | Use case | Owner | Server access |
|-------|----------|-------|---------------|
| User-owned | Self-custodial consumer wallets | User | None |
| User + server | Automated trading, limit orders | User | Scoped via policies |
| Application-owned | Treasury, agents, bots | Authorization key | Full |
| Custodial | Institutional, FBO accounts | Licensed custodian | Full |

### When to use policies vs MFA

| Requirement | Use policy | Use MFA |
|-------------|-----------|---------|
| Limit transaction amounts | ✓ | |
| Restrict recipient addresses | ✓ | |
| Require human approval | | ✓ |
| Time-based restrictions | ✓ | |
| Prevent unauthorized access | | ✓ |
| Enforce smart contract rules | ✓ | |

### Authentication method selection

| Method | Best for | Setup |
|--------|----------|-------|
| Email + OTP | General users | Enable in dashboard |
| Social (Google, Discord) | Broad accessibility | Configure OAuth apps |
| Passkeys | High security | Enable in dashboard |
| Wallet (SIWE/SIWS) | Crypto-native users | Enable in dashboard |
| Custom JWT | Existing auth system | Integrate via API |

## Workflow

### 1. Set up your Privy app

1. Create an app in the Privy Dashboard
2. Copy your **App ID** and **App Secret** from App settings > Basics
3. Configure login methods in Dashboard > Authentication
4. Set up webhook endpoint and signing secret (if using webhooks)
5. Add allowed domains in Dashboard > App clients

### 2. Initialize the SDK in your app

**For React/React Native:**
- Wrap your app with `PrivyProvider` at the root
- Pass `appId` and optional `clientId`
- Configure `embeddedWallets` to auto-create wallets on login
- Wait for `ready` flag before consuming Privy state

**For server-side (NodeJS, Go, Java, etc.):**
- Initialize client with App ID and App Secret
- Store credentials securely in environment variables
- Use client to make authenticated API calls

### 3. Authenticate users

1. Use `usePrivy()` hook (React) or SDK login methods to authenticate
2. Privy returns a user object with unique ID and linked accounts
3. Access token is automatically managed by the SDK
4. For server-side, use user ID to create or fetch wallets

### 4. Create or access wallets

1. **Client-side**: Use `useCreateWallet()` or `useEmbeddedEthereumWallet()` to create wallets
2. **Server-side**: Call `POST /v1/wallets` with owner (user ID or authorization key)
3. Specify chain type (ethereum, solana, etc.)
4. Optionally attach policies and signers at creation time
5. Store wallet ID for future operations

### 5. Execute transactions

1. Get wallet instance from SDK or API
2. Call appropriate signing method (`sendTransaction`, `signMessage`, etc.)
3. Privy evaluates policies in secure enclave
4. User approves if required (MFA, policy action)
5. Transaction is signed and broadcast
6. Subscribe to webhooks for confirmation events

### 6. Manage controls and policies

1. Create policies via `POST /v1/policies` with rules and conditions
2. Attach policy to wallet at creation or via update
3. Define conditions (transaction limits, recipient addresses, time windows)
4. Set action (ALLOW, DENY, ALLOW_WITH_MFA)
5. Update policies via intents if wallet has approval requirements

### 7. Monitor and react to events

1. Set up webhook endpoint that accepts POST requests
2. Verify webhook signature using Svix headers and signing secret
3. Parse webhook payload to determine event type
4. React to events (user.created, transaction.confirmed, etc.)
5. Return 2xx status to acknowledge delivery

## Common gotchas

- **HTTPS required for embedded wallets**: Embedded wallets only work in secure contexts (https://). Localhost is treated as secure by browsers, but http:// deployments will fail silently.

- **Wait for `ready` flag**: Don't consume Privy state before `usePrivy().ready` is true. This causes stale data and race conditions.

- **Policy evaluation happens in enclave**: Policies are evaluated inside secure execution environments. You cannot inspect or modify policy logic at runtime—define policies upfront.

- **Idempotency keys prevent duplicates**: Use idempotency keys on wallet creation and transaction endpoints to prevent duplicate operations if requests retry.

- **Webhook verification is mandatory**: Always verify webhook signatures before processing. Unverified webhooks can be spoofed.

- **Rate limits apply to REST API**: Implement exponential backoff when you receive HTTP 429 responses. Batch requests and cache results where possible.

- **User ID is immutable**: Once a user is created, their ID cannot change. Use external_id for your own identifiers.

- **Policies are chain-specific**: A policy for Ethereum won't apply to Solana wallets. Create separate policies per chain.

- **Authorization keys are permanent**: Once created, authorization key public keys cannot be rotated. Plan key management carefully.

- **Entity assignment is permanent**: When you assign a wallet to a user or organization via `entity`, it cannot be changed later.

- **Signers cannot modify policies**: Additional signers can execute transactions but cannot change wallet ownership or policies.

- **MFA state is per-user**: MFA enrollment is tied to the user, not the wallet. Disabling MFA affects all wallets for that user.

## Verification checklist

Before submitting work with Privy:

- [ ] App ID and App Secret are stored securely (environment variables, not hardcoded)
- [ ] PrivyProvider wraps the entire app (React) or client is initialized (server-side)
- [ ] Webhook endpoint verifies signatures before processing
- [ ] Policies are defined and attached to wallets before transactions
- [ ] User is authenticated before accessing wallet methods
- [ ] `ready` flag is checked before consuming Privy state (client-side)
- [ ] Idempotency keys are used on create/transaction endpoints
- [ ] Error handling covers API errors (4xx, 5xx) and policy violations
- [ ] Webhook events are subscribed to for monitoring (transaction.confirmed, etc.)
- [ ] Rate limiting is handled with exponential backoff
- [ ] HTTPS is enforced for production deployments
- [ ] Allowed domains are configured in Dashboard for your deployment URL
- [ ] MFA is enabled for sensitive operations (if required)
- [ ] External IDs are used consistently for your own identifiers
- [ ] Wallet addresses are validated before use

## Resources

**Comprehensive navigation**: https://docs.privy.io/llms.txt

**Critical documentation pages**:
1. [Key Concepts](https://docs.privy.io/basics/key-concepts) — Understand authentication, wallets, and controls
2. [REST API Introduction](https://docs.privy.io/api-reference/introduction) — API authentication and rate limits
3. [Wallet Controls Overview](https://docs.privy.io/controls/overview) — Policies, owners, and signers

---

> For additional documentation and navigation, see: https://docs.privy.io/llms.txt