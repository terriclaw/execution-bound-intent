# execution-bound-intent

> **delegation without interpretation**

A primitive where a signed authorization is only valid if the actual onchain execution exactly matches the committed execution.

## What this is

Most delegation and permission systems ask: is this action allowed?

execution-bound-intent asks: does the actual execution exactly match what was committed?

This is not a policy engine. It is a commitment verification system.

## The invariant

At redemption, ExecutionBoundCaveat enforces:

- intent.account == _delegator
- intent.target == execution.target
- intent.value == execution.value
- intent.dataHash == keccak256(execution.callData)
- block.timestamp <= intent.deadline (if set)
- usedNonces[account][signer][nonce] == false
- valid EOA or ERC-1271 signature over EIP-712 digest

Any mismatch reverts. No interpretation. No flexibility.

## What it guarantees

- No parameter tampering by relayers
- No target substitution
- No calldata drift
- No chain replay (EIP-712 domain binds chain + contract)
- No intent replay (nonce consumed on first use)

## What it does not guarantee

- Correct reasoning behind the intent
- Economic optimality of the committed call
- Downstream contract behavior depending on external state
- MEV resistance beyond execution integrity

## Setup

    forge install foundry-rs/forge-std
    forge install OpenZeppelin/openzeppelin-contracts
    forge build
    forge test

## Nonce model

Scoped by (account, signer, nonce). Unordered — any value valid once.

## ERC-7710 integration

beforeHook args (per-redemption):
    abi.encode(ExecutionIntent intent, address signer, bytes signature)

terms: unused in v1, pass empty bytes.

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
