# execution-bound-intent

> **delegation without interpretation**

**Invariant:**

    keccak256(execution.callData) == intent.dataHash
    AND execution.target          == intent.target
    AND execution.value           == intent.value
    AND intent.account            == delegator

Authorization is reduced to byte-level equality, eliminating policy interpretation.

A canonical equality-based caveat for execution commitment.

## Why this matters

Policy-based caveats can allow silent parameter mutation.

A selector-only check (e.g. AllowedMethods) verifies the function, but not the parameters. A relayer can change the recipient or amount while still passing validation.

execution-bound-intent prevents this by enforcing exact calldata equality at runtime — any deviation reverts.

    Policy checks:     "is this allowed?"
    Execution-bound:   "is this exactly what was signed?"

See: test/RelayerMutationDemo.t.sol

- test_policyEnforcer_allowsRelayerMutation -> mutation passes silently
- test_executionBoundCaveat_blocksRelayerMutation -> revert

## What this is

Most delegation and permission systems ask: is this action allowed?

execution-bound-intent asks: does the actual execution exactly match what was committed?

This is not a policy engine. It is a commitment verification system.

delegator = the smart account executing via DelegationManager (passed as _delegator in the caveat hook)

execution.callData is extracted from the packed execution via ERC-7579 ExecutionLib.decodeSingle() and refers only to the function calldata (not the packed envelope).

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

## Flow

    1. signer builds ExecutionIntent
    2. signer signs EIP-712 digest
    3. intent + sig passed as caveat args at redemption
    4. execution submitted via DelegationManager
    5. caveat decodes real calldata via ExecutionLib.decodeSingle()
    6. caveat recomputes hash + verifies signature
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
- front-running an identical execution (by design: commitment is to the call, not the caller)

## Composability

Multiple caveats can be stacked; all must pass, enabling strict conjunction: all commitments must independently hold.

## ERC-7710 / DelegationManager integration

See INTEGRATION.md for a full reference integration.

beforeHook args (per-redemption):

    abi.encode(ExecutionIntent intent, address signer, bytes signature)

signer is the address expected to have produced the signature (distinct from _redeemer).
terms: unused in v1, pass empty bytes.
mode: accepted but not inspected — v1 assumes single call type.

## Standardization surface

- ExecutionIntent struct
- EIP-712 typehash and domain model
- equality invariant
- nonce scoping by (account, signer)

## Nonce model

    mapping(address account => mapping(address signer => mapping(uint256 nonce => bool))) usedNonces;

Scoped by (account, signer). Unordered — any value valid once.

## Setup

    forge install foundry-rs/forge-std
    forge install OpenZeppelin/openzeppelin-contracts
    forge install erc7579/erc7579-implementation
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
