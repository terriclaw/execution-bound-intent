# DelegationManager Integration Reference

This document shows how to wire ExecutionBoundCaveat into a MetaMask
delegation-framework redemption as a caveat.

## How it fits

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
        verifyingContract: CAVEAT_ENFORCER_ADDRESS,
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
    4. Caveat checks all equality conditions
    5. Caveat verifies EIP-712 signature
    6. Caveat consumes nonce
    7. DelegationManager proceeds with execution

If any check fails, the entire redemption reverts.

## Encoding note

executionCalldata is packed as:

    abi.encodePacked(target, value, calldata)

decodeSingle() extracts:
- target:   bytes [0:20]
- value:    bytes [20:52]
- callData: bytes [52:]

dataHash must be keccak256(callData) — not keccak256(the full packed envelope).
