# Execution-Bound Intent: Removing Relayer Discretion from Delegated Execution

## The problem

Delegation systems answer one question: who is authorized to act? The delegation signature establishes authority. But it does not constrain what gets executed.

In a standard redemption flow, the redeemer constructs the execution calldata and submits it. If a static caveat (e.g. allowed methods, value limits) is attached, the redeemer must stay within those bounds — but has full discretion over everything else. Recipient, amount, function arguments: all mutable. A relayer operating within policy can still substitute parameters the delegator never intended.

This is not a flaw in the caveat model. It is the limit of policy-based enforcement.

## The insight

There are two distinct authorization surfaces in a delegation flow:

- The delegation signature answers: who may redeem this?
- The execution intent answers: what exact call is authorized?

Existing systems bind the first. Execution-bound intent binds the second.

## The mechanism

An ExecutionIntent is a second EIP-712 signed message committing to:

    account, target, value, keccak256(calldata), nonce, deadline

At redemption, the redeemer passes this intent alongside the delegation. A caveat enforcer verifies:

- intent.account == _delegator
- intent.target == execution.target
- intent.value == execution.value
- keccak256(execution.callData) == intent.dataHash
- nonce unused, deadline valid, signature valid

Any deviation — a single byte of calldata, a different recipient, a different amount — reverts. The nonce is consumed only after signature verification, preventing griefing.

The intent is injected at redemption time via caveat.args, which is excluded from the delegation hash by design. The redeemer cannot substitute a different intent because the caveat binds it back to the delegator and exact execution.

## Why it matters

This converts execution from a constrained policy check into a commitment check. The relayer has no discretion. There is no interpretation. The executed call either matches the signed commitment exactly or it reverts.

No partial matches. No parameter tolerance.

## vs. exactExecution

exactExecution (static caveat) commits to execution at delegation time — the calldata is fixed when the delegation is signed.

Execution-bound intent commits at redemption time — the signer produces the intent separately, and the redeemer injects it. This allows the authorized execution to be determined closer to redemption without giving the redeemer discretion over its content.

Both enforce exactness. The distinction is when the commitment is made and who holds the signing key.
