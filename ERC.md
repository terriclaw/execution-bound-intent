# ERC-XXXX: Execution-Bound Intent

## Abstract

This standard defines a minimal primitive for execution commitment in delegated transaction systems. A signed `ExecutionIntent` is valid if and only if the actual onchain execution exactly matches all committed fields. Authorization is reduced to byte-level equality, eliminating policy interpretation and relayer discretion.

## Motivation

Existing delegation systems enforce execution through policy-based caveats: allowlists, value limits, method selectors, time windows. These systems ask whether an action is permitted within a policy.

No standard exists for the stronger primitive: committing to an exact execution such that any deviation causes reversion.

This gap creates exploitable surface in delegated systems:

- Relayers substituting calldata within policy bounds
- Ambiguous authorization scope across accounts
- Stale authorizations reused in unintended contexts
- Parameter drift between signed intent and executed call

This standard defines a canonical commitment scheme where the signed authorization and the executed call must be identical.

## Specification

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

### Definitions

**ExecutionIntent**: A signed commitment to an exact execution, identified by a canonical EIP-712 struct.

**delegator**: The smart account on whose behalf execution is authorized. Passed as `_delegator` by the delegation framework at redemption time.

**signer**: The address whose signature authorizes the intent. MAY be an EOA or ERC-1271 smart contract.

**execution.callData**: The function calldata of the call to be executed. This refers strictly to the calldata bytes, not any packed execution envelope.

**dataHash**: keccak256(execution.callData). Binds the selector and all calldata parameters.

### Intent Struct
```solidity
struct ExecutionIntent {
    address account;   // the delegating smart account
    address target;    // call target
    uint256 value;     // ETH value of the call
    bytes32 dataHash;  // keccak256(execution.callData)
    uint256 nonce;     // replay guard, scoped by (account, signer)
    uint256 deadline;  // unix timestamp expiry; 0 = no expiry
}
```

Implementations MUST NOT extend this struct with additional fields in v1.

### EIP-712 Typehash
```solidity
bytes32 constant EXECUTION_INTENT_TYPEHASH = keccak256(
    "ExecutionIntent(address account,address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)"
);
```

### EIP-712 Domain

The enforcing contract MUST define its domain separator as:
```solidity
keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("ExecutionBoundIntent"),
    keccak256("1"),
    block.chainid,
    address(this)
));
```

The enforcing contract is the EIP-712 domain anchor. Digests are scoped to the deploying contract on the deploying chain.

### Digest Construction
```solidity
bytes32 digest = keccak256(abi.encodePacked(
    "\x19\x01",
    DOMAIN_SEPARATOR,
    keccak256(abi.encode(
        EXECUTION_INTENT_TYPEHASH,
        intent.account,
        intent.target,
        intent.value,
        intent.dataHash,
        intent.nonce,
        intent.deadline
    ))
));
```

### Enforcement Invariant

At redemption, an enforcer MUST verify all of the following, in order:

1. intent.account == _delegator
2. intent.target == execution.target
3. intent.value == execution.value
4. intent.dataHash == keccak256(execution.callData)
5. intent.deadline == 0 OR block.timestamp <= intent.deadline
6. usedNonces[intent.account][signer][intent.nonce] == false
7. Signature is valid over the EIP-712 digest for signer (EOA or ERC-1271)
8. Mark usedNonces[intent.account][signer][intent.nonce] = true

The enforcer MUST revert if any condition fails. The nonce MUST be consumed only after successful signature verification.

### Nonce Model
```solidity
mapping(address account => mapping(address signer => mapping(uint256 nonce => bool))) usedNonces;
```

Nonces MUST be scoped by (account, signer). A signer's nonce space is independent per smart account, preventing cross-account replay of the same signed intent. Nonces are unordered. Any unused value is valid. Implementations MUST NOT require sequential nonce ordering.

### Signature Verification

Implementations MUST support EOA signatures via ecrecover and ERC-1271 smart contract signatures via isValidSignature. Support for ERC-7913 address-less verifiers is OPTIONAL and out of scope for v1.

### Calldata Encoding

When used with ERC-7579-compatible execution frameworks, execution.callData MUST be extracted from the packed execution envelope:

    executionCalldata = abi.encodePacked(target, value, callData)

Where target is bytes [0:20], value is bytes [20:52], and callData is bytes [52:].

dataHash MUST be keccak256(callData), not keccak256(executionCalldata).

## Rationale

### Why full execution commitment only

Partial commitment modes (selector-only, value-range, target-only) are expressible as weaker caveats in existing systems. This standard defines only the strongest form: full equality. Weaker forms are out of scope and may be defined in separate ERCs.

### Why account binding

Without binding intent.account to the delegator context, the same signed intent is valid across any account controlled by the signer. Account binding closes cross-account replay without requiring additional nonce coordination.

### Why signer-scoped nonces

Digest-consumption replay prevention is semantically clean but prevents intent cancellation. Ordered nonces block unrelated intents if one stalls. Signer-scoped unordered nonces allow independent intent management per (account, signer) pair without coordination overhead.

### Why EIP-712 only

Supporting multiple digest modes introduces ambiguity about which encoding was signed. A single canonical digest format eliminates this class of mismatch entirely.

### Why chainId in domain only

Including chainId in both the domain and the struct is redundant given EIP-712 domain separation. The domain binds chain and contract. Adding it to the struct would require signers to commit to it twice without benefit.

## Security Considerations

### What this standard prevents

- Relayer calldata substitution
- Target substitution
- Value mutation
- Cross-chain replay (EIP-712 domain binds chainId)
- Cross-contract replay (EIP-712 domain binds verifyingContract)
- Intent replay (nonce consumption)
- Stale authorization reuse (deadline)

### What this standard does not prevent

- Signer key compromise
- A user signing a malicious or incorrect intent
- Front-running of an identical execution (the commitment is to the call, not the caller)
- Downstream contract behavior that depends on external mutable state
- Semantic mismatch between human expectation and committed bytes

Implementations SHOULD communicate clearly to signers that the nonce is irrevocable once consumed, and that the commitment is to exact bytes, not to intent or outcome.

## Reference Implementation

Available at: github.com/terriclaw/execution-bound-intent

- ExecutionIntentLib.sol: canonical EIP-712 struct and digest construction
- ExecutionBoundCaveat.sol: reference enforcer implementing the full invariant
- ts/buildExecutionIntent.ts: offchain intent builder
- ts/signExecutionIntent.ts: EIP-712 signer

## Copyright

Copyright and related rights waived via CC0.
