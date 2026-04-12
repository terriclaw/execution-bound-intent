# execution-bound-intent

> **exact execution or revert**

A terminal enforcement primitive for delegated execution.
Binds execution to a signed intent at redemption.

**Live explainer:** https://terriclaw.github.io/execution-bound-intent/

**Invariant:**

    keccak256(execution.callData) == intent.dataHash
    AND execution.target          == intent.target
    AND execution.value           == intent.value
    AND intent.account            == _delegator

Execution succeeds only if signature validity and exact equality both hold.

Enforced at redemption time inside the DelegationManager caveat hook.

Delegation defines who may execute.
execution-bound-intent defines what must be executed.
Enforcement happens only at redemption.

No partial matches. No parameter tolerance. Equality is strict.

Any transformation to the committed execution invalidates the transaction.

account, target, value, calldata, nonce, and deadline are all part of the signed commitment.

## Why this matters

Policy-based caveats can allow silent parameter mutation.

A selector-only check (e.g. AllowedMethods) verifies the function, but not the parameters. A relayer can change the recipient or amount while still passing validation.

execution-bound-intent enforces exact execution equality at redemption; any deviation reverts.

    Policy checks:     "is this allowed?"
    Execution-bound:   "is this exactly what was signed?"

This gap appears whenever execution is delegated and calldata is constructed off-chain.

See: [`test/RelayerMutationDemo.t.sol`](./test/RelayerMutationDemo.t.sol)

- `test_policyEnforcer_allowsRelayerMutation` -> mutation passes silently
- `test_executionBoundCaveat_blocksRelayerMutation` -> revert

## What this is

Not a policy engine. A byte-level commitment check that verifies execution exactly matches what was signed, evaluated only at redemption.

delegator = the smart account executing via DelegationManager (passed as _delegator in the caveat hook)

execution.callData includes the full function selector and arguments, but excludes target and value (each checked separately). Extracted via ERC-7579 ExecutionLib.decodeSingle(). Assumes single-call execution encoding — multicall not supported in v1. Delegatecall, batch, static, and unknown call types are rejected at the enforcement boundary.

## Example

    ExecutionIntent:
      account:  0xAlice
      target:   0xUSDC
      value:    0
      dataHash: keccak256(transfer(0xBob, 100e6))
      nonce:    1
      deadline: 0

    Result:
      transfer(0xBob, 100e6)  -> pass
      transfer(0xBob, 101e6)  -> revert (DataHashMismatch)
      transfer(0xEve, 100e6)  -> revert (DataHashMismatch)
      approve(0xEve, 100e6)   -> revert (DataHashMismatch)
      same intent submitted twice -> revert (NonceAlreadyUsed)

Modifying a single byte of calldata causes a DataHashMismatch revert.
The commitment is to exact bytes, not to intent or meaning.
The commitment is to bytes, not semantics.

## Signer vs delegator

The signer may be distinct from the delegating account (`_delegator`). Authorization is via signature; execution is via account. A session key, agent, or co-signer may sign on behalf of the delegating smart account.

## Signature domain

Signature domain includes chainId and verifying contract address, preventing cross-domain replay without additional coordination.

## Flow

    1. ExecutionIntent is constructed (by app, agent, or wallet)
    2. authorized signer signs EIP-712 digest bound to (account, target, value, calldata, nonce, deadline)
    3. intent + sig passed as caveat args at redemption
    4. execution submitted via DelegationManager
    5. caveat decodes real calldata via ExecutionLib.decodeSingle()
    6. caveat recomputes hash, consumes nonce, then verifies signature (CEI)
    7. equality holds -> execute; else revert

## The struct

    struct ExecutionIntent {
        address account;   // the delegating smart account
        address target;
        uint256 value;
        bytes32 dataHash;  // keccak256(execution.callData)
        uint256 nonce;
        uint256 deadline;  // 0 = no expiry
    }

## Enforcement

At redemption, ExecutionBoundCaveat checks in order:

- intent.account == _delegator         (binds to specific smart account, prevents cross-account replay)
- intent.target == execution.target
- intent.value == execution.value
- intent.dataHash == keccak256(execution.callData)
- intent.deadline == 0 OR block.timestamp <= intent.deadline
- usedNonces[account][signer][nonce] == false
- valid EOA or ERC-1271 signature over the EIP-712 digest of ExecutionIntent
- nonce is consumed before signature verification (CEI compliance)

Any mismatch reverts. No interpretation. No flexibility.

## Threat model

Prevented:

- relayer-controlled calldata mutation -> exact equality enforcement at redemption
- replay across domains -> prevented by EIP-712 domain separation (chainId + verifyingContract)
- replay within the same domain -> prevented by nonce scoping to (account, signer, nonce)
- cross-account reuse -> prevented by account binding in the signed intent
- signature spoofing -> prevented by EOA / ERC-1271 signature verification

Not prevented:

- signer key compromise
- user signing a malicious intent
- front-running an identical execution (by design: commitment is to the call, not the caller)
- downstream contract behavior depending on mutable external state

## Composability

Multiple caveats can be stacked; all must pass. This enables strict conjunction: each commitment must independently hold. This enables commitment layering.

## ERC-7710 / DelegationManager integration

See [`INTEGRATION.md`](./docs/INTEGRATION.md) for a full reference integration.

beforeHook args (per-redemption):

    abi.encode(ExecutionIntent intent, address signer, bytes signature)

signer is the address expected to have produced the signature (distinct from _redeemer).
terms: unused in v1, pass empty bytes.
mode: inspected for call type; only CALLTYPE_SINGLE is accepted. Delegatecall, batch, static, and unknown call types revert with UnsupportedCallType.

## Standardization surface

- ExecutionIntent struct
- EIP-712 typehash and domain model
- equality invariant
- nonce scoping by (account, signer)

## Nonce model

    mapping(address account => mapping(address signer => mapping(uint256 nonce => bool))) usedNonces;

Scoped by (account, signer). Unordered — any value valid once.


## Gas

Benchmarked against a selector-only baseline enforcer.

| Calldata size | ExecutionBoundCaveat | Selector-only | Overhead |
|---|---|---|---|
| Small (68 bytes)  | 60,793 gas | 15,900 gas | +44,893 (~3.8x) |
| Medium (324 bytes) | 62,031 gas | 17,060 gas | +44,971 (~3.6x) |
| Large (256 bytes) | 61,798 gas | 16,875 gas | +44,923 (~3.7x) |

Overhead is flat across calldata sizes. Cost is dominated by EIP-712 digest construction and ecrecover (~45k gas), not calldata hashing. keccak256 of calldata is cheap.

Cost is constant per execution, not proportional to calldata size.
This cost profile favors high-value, low-frequency execution paths.

See: [`test/GasBenchmarks.t.sol`](./test/GasBenchmarks.t.sol)

## Public proof — Base Sepolia

[`docs/testnet-demo.md`](./docs/testnet-demo.md)

Flow 1 (exact execution) is live onchain. Flows 2 (mutation) and 3 (replay) revert as expected (proven in simulation).

- Exact execution tx: `0x03197ac7f52ce016449270efc564b1d3ab547e70bdb0bdd4ff0007d136264801`
- ExecutionBoundCaveat: `0xD4c2D166839a6cCDb9Bf0f3cD292686587Ae9Eb6`
- Live explainer: https://terriclaw.github.io/execution-bound-intent/

## Flowwire — full ERC-7710 redemption path

[`test/Flowwire7710.t.sol`](./test/Flowwire7710.t.sol) proves the primitive inside the real MetaMask delegation framework stack — not just at the `beforeHook` boundary.

**Two signatures, kept separate:**

    [Sig 1] Delegator signs delegation via DelegationManager EIP-712 domain
            → says who may redeem
    [Sig 2] Signer signs ExecutionIntent via ExecutionBoundCaveat EIP-712 domain
            → says what exact execution is allowed

**Key finding:** `args` is excluded from the delegation hash by design. The redeemer injects the signed ExecutionIntent at redemption time — but the caveat binds it back to `_delegator`, `target`, `value`, `calldata`, `nonce`, and signature validity. The redeemer cannot substitute a different intent.

**Four cases proven through real DelegationManager:**
- exact execution → `demoTarget.value() == 42`
- mutated calldata → `DataHashMismatch` revert
- replay → `NonceAlreadyUsed` revert
- non-single call type → `UnsupportedCallType` revert

## Intended default path

The intended path: scope execution to an explicit execution context — a specific manager or redemption authority.

The primitive supports this through the `authorizedSigner` in `terms` (framework port) and the two-signature model: delegation defines who may redeem, ExecutionIntent defines what must execute.

See [`docs/INTEGRATION.md`](./docs/INTEGRATION.md) for the reference integration pattern.

## Canonical flow

Start here:

- [`test/CanonicalFlow.t.sol`](./test/CanonicalFlow.t.sol) — minimal step-by-step usage path, no framework complexity

Shows: build intent -> sign -> enforce -> execute -> verify. Easy to copy.

For proof the primitive survives the real MetaMask delegation stack, see [`test/Flowwire7710.t.sol`](./test/Flowwire7710.t.sol).

## Related research

A companion repo explores the broader design space that informed the canonical path:

https://github.com/terriclaw/execution-bound-intent-global-replay

It covers:
- replay semantics and nonce scoping models
- ManagerBoundIntent vs GlobalIntent type separation
- why intent type must survive relayer, integration, ops, and schema boundaries
- executable proofs of failure modes at each layer

This repo (execution-bound-intent) focuses on the primitive itself.
The research repo explains why the canonical path is the right one.

## Integration flow

[`test/IntegrationFlow.t.sol`](./test/IntegrationFlow.t.sol) exercises the same `beforeHook` path that `DelegationManager` calls at redemption time — same args encoding, same `ExecutionLib.encodeSingle` executionCalldata, same mode byte.

Five cases: exact execution passes, mutated calldata reverts, wrong account reverts, nonce lifecycle verified, delegatecall rejected.

This validates enforcement at the DelegationManager boundary directly. For the full real redemption path, see [`test/Flowwire7710.t.sol`](./test/Flowwire7710.t.sol).

## Setup

    forge install foundry-rs/forge-std
    forge install OpenZeppelin/openzeppelin-contracts
    forge install erc7579/erc7579-implementation
    forge build
    forge test

## Scope

Designed for payment and execution paths where exactness is required. Not intended for flexible agent decision layers or policy-based authorization.

This primitive optimizes for correctness, not flexibility or low-cost repeated execution.

## Deferred (not v1)

- Partial commitment caveats
- ERC-7913 support
- TEE / provenance layers
- Batch / multicall
- Policy systems

## Relation to prior work

- OnlyAgent: TEE-backed AI execution proofs gating onchain behavior
- OnlyAgentProofCaveat: commitment verification at delegation layer; direct precursor

execution-bound-intent generalizes beyond AI and beyond one provider.
The primitive is execution equality, not reasoning correctness.
It does not decide what should happen — only that what happens is exactly what was signed.
