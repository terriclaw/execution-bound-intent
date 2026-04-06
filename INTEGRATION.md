# DelegationManager Integration Reference

This document shows how to wire ExecutionBoundCaveat into a MetaMask
delegation-framework redemption as a caveat.

## Signer vs delegator

The signer may differ from the delegator. The signature authorizes the execution; the delegator account executes it. A session key, agent, or co-signer may sign on behalf of the delegating smart account.

## How it fits

v1 supports only single-call execution encoding (CALLTYPE_SINGLE = 0x00). Delegatecall, batch, static, and unknown call types are rejected with UnsupportedCallType. This is enforced in the beforeHook via the ModeCode first byte.

In the MM delegation framework, a Delegation carries a list of Caveats.
Each Caveat has an enforcer address, terms (static config), and args (per-redemption payload).

ExecutionBoundCaveat is the enforcer. It enforces that the actual execution
exactly matches a signed ExecutionIntent passed in args.

## Caveat construction (offchain)

    // 1. Build the calldata you intend to execute
    const calldata = encodeFunctionData({
      abi: erc20Abi,
      functionName: "transfer",
      args: [recipient, amount],
    });

    // 2. Build the intent
    const intent = {
      account:  delegatorAddress,
      target:   tokenAddress,
      value:    0n,
      dataHash: keccak256(calldata),
      nonce:    1n,
      deadline: 0n,
    };

    // 3. Sign via EIP-712
    const signature = await wallet.signTypedData({
      domain: {
        name: "ExecutionBoundIntent",
        version: "1",
        chainId,
        verifyingContract: CAVEAT_ENFORCER_ADDRESS, // scopes signatures to this primitive specifically
      },
      types: {
        ExecutionIntent: [
          { name: "account",  type: "address" },
          { name: "target",   type: "address" },
          { name: "value",    type: "uint256" },
          { name: "dataHash", type: "bytes32" },
          { name: "nonce",    type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "ExecutionIntent",
      message: intent,
    });

    // 4. Encode caveat args (passed at redemption time)
    const args = encodeAbiParameters(
      [
        { type: "tuple", components: [
          { name: "account",  type: "address" },
          { name: "target",   type: "address" },
          { name: "value",    type: "uint256" },
          { name: "dataHash", type: "bytes32" },
          { name: "nonce",    type: "uint256" },
          { name: "deadline", type: "uint256" },
        ]},
        { type: "address" },
        { type: "bytes" },
      ],
      [intent, signerAddress, signature]
    );

    // 5. Attach to delegation
    const delegation = {
      delegate:  redeemer,
      delegator: delegatorAddress,
      authority: ROOT_AUTHORITY,
      caveats: [{
        enforcer: CAVEAT_ENFORCER_ADDRESS,
        terms:    "0x",   // unused in v1
        args,
      }],
      salt: 0n,
      signature: "0x",   // filled after delegator signs delegation
    };

## What happens at redemption

When the redeemer calls DelegationManager.redeemDelegation():

    1. DelegationManager calls ExecutionBoundCaveat.beforeHook(terms, args, mode, executionCalldata, ...)
    2. Caveat decodes intent + signer + signature from args
    3. Caveat decodes target + value + callData from executionCalldata via ExecutionLib.decodeSingle()
    4. Caveat checks nonce unused
    5. Caveat checks equality conditions (account, target, value, dataHash, deadline)
    6. Caveat verifies EIP-712 signature
    7. Caveat consumes nonce
    8. DelegationManager proceeds with execution

If any check fails, the entire redemption reverts. No partial execution is possible.

Invariant enforced:

    keccak256(callData) == intent.dataHash
    AND target          == intent.target
    AND value           == intent.value
    AND _delegator      == intent.account
    AND (intent.deadline == 0 OR block.timestamp <= intent.deadline)

The nonce MUST be checked as unused before signature verification and consumed only after successful verification.

## Encoding note

In ERC-7579-compatible implementations, executionCalldata is commonly packed as (assumes fixed-width: target 20 bytes, value 32 bytes):

    abi.encodePacked(target, value, calldata)

Where target is bytes [0:20], value is bytes [20:52], and callData is bytes [52:].

Implementations MUST extract callData (the function calldata) and compute:

    dataHash = keccak256(callData)

dataHash MUST NOT be keccak256(the full packed envelope).
