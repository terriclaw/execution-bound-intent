# execution-bound-intent

> **delegation without interpretation**

**Invariant:**

    keccak256(execution.callData) == intent.dataHash
    AND execution.target          == intent.target
    AND execution.value           == intent.value
    AND intent.account            == delegator

Authorization is reduced to byte-level equality, eliminating policy interpretation.

A canonical equality-based caveat for execution commitment.

## What this is

Most delegation and permission systems ask: is this action allowed?

execution-bound-intent asks: does the actual execution exactly match what was committed?

This is not a policy engine. It is a commitment verification system.

delegator = the smart account executing via DelegationManager (passed as _delegator in the caveat hook)

execution.callData refers only to the function calldata, not the full packed execution envelope.

## Flow

    1. signer builds ExecutionIntent
    2. signer signs EIP-712 digest
    3. intent + sig passed as caveat args at redemption
    4. execution submitted via DelegationManager
    5. caveat recomputes hash + verifies signature
    6. equality holds -> execute; else revert

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

- intent.account == _delegator         (binds authorization to a specific smart account context, preventing cross-account replay)
- intent.target == execution.target
- intent.value == execution.value
- intent.dataHash == keccak256(execution.callData)
- intent.deadline == 0 OR block.timestamp <= intent.deadline
- usedNonces[account][signer][nonce] == false
- valid EOA or ERC-1271 signature over the EIP-712 digest of ExecutionIntent
- nonce is consumed only after successful signature verification

Any mismatch reverts. No interpretation. No flexibility.

## Threat model

Prevented:

- replay attack          -> nonce scoped by [account][signer][nonce]
- cross-account reuse    -> account binding in struct
- calldata mutation      -> keccak256(execution.callData) == intent.dataHash
- cross-contract replay  -> EIP-712 domain (verifyingContract)
- signature spoofing     -> EOA / ERC-1271 via OZ SignatureChecker

Not prevented:

- signer key compromise
- user signing a malicious intent
- front-running an identical execution (by design: the commitment is to the call, not the caller)

## Composability

Multiple caveats can be stacked; all must pass, enabling strict conjunction: all commitments must independently hold.

## ERC-7710 integration

beforeHook args (per-redemption):

    abi.encode(ExecutionIntent intent, address signer, bytes signature)

signer is the address expected to have produced the signature (distinct from _redeemer).
terms: unused in v1, pass empty bytes.

## Standardization surface

The standardizable pieces are narrow and intentional:

- ExecutionIntent struct
- EIP-712 typehash and domain model
- equality invariant
- nonce scoping by (account, signer)

That is sufficient to describe in one paragraph and small enough for others to adopt.

## Nonce model

    mapping(address account => mapping(address signer => mapping(uint256 nonce => bool))) usedNonces;

Scoped by (account, signer). Unordered — any value valid once.

## Setup

    forge install foundry-rs/forge-std
    forge install OpenZeppelin/openzeppelin-contracts
    forge build
    forge test

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
