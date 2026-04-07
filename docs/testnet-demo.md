## execution-bound-intent
enforces exact execution at redemption using a second EIP-712 signature, removing relayer discretion.

# Testnet Demo — Base Sepolia

Public onchain proof of execution-bound-intent running through the real MetaMask DelegationManager.

## Network

Base Sepolia (chain ID 84532)

## Deployed contracts

| Contract | Address |
|---|---|
| ExecutionBoundCaveat | [0xD4c2D166839a6cCDb9Bf0f3cD292686587Ae9Eb6](https://sepolia.basescan.org/address/0xD4c2D166839a6cCDb9Bf0f3cD292686587Ae9Eb6) |
| DemoTarget | [0x6bAaC44B3Dc269012829e591d256Ea8d5D8F15Db](https://sepolia.basescan.org/address/0x6bAaC44B3Dc269012829e591d256Ea8d5D8F15Db) |
| DelegatorAccount (HybridDeleGator proxy) | [0xA7858cbB8be2cD50cc9e04e62eCD58BF86381137](https://sepolia.basescan.org/address/0xA7858cbB8be2cD50cc9e04e62eCD58BF86381137) |
| DelegationManager (MM v1.3.0) | [0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3](https://sepolia.basescan.org/address/0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3) |

## Flow 1 — exact execution (onchain)

Transaction: https://sepolia.basescan.org/tx/0x03197ac7f52ce016449270efc564b1d3ab547e70bdb0bdd4ff0007d136264801
Block: 39881550

What happened:
- Signed ExecutionIntent committing to setValue(42) on DemoTarget
- Signed delegation authorizing redeemer via HybridDeleGator
- Called DelegationManager.redeemDelegations
- ExecutionBoundCaveat.beforeHook enforced exact byte equality
- executeFromExecutor ran setValue(42)

Events emitted:
- NonceConsumed(account, signer, 0) from ExecutionBoundCaveat
- ValueSet(42) from DemoTarget
- RedeemedDelegation from DelegationManager

Status: success

This demonstrates that execution is enforced as a commitment check at redemption, not a policy evaluated by the relayer.

## Flow 2 — mutated calldata (simulation)

Same signed intent. Redeemer submitted setValue(999) instead.
ExecutionBoundCaveat reverted: DataHashMismatch.
Proven in simulation — expected reverts are not broadcast.

## Flow 3 — replay (simulation)

Same signed intent. Nonce 0 already consumed in Flow 1.
ExecutionBoundCaveat reverted: NonceAlreadyUsed.
Proven in simulation — expected reverts are not broadcast.

## Run command

    forge script script/TestnetDemo.s.sol \
      --rpc-url $RPC_URL \
      --private-key $DELEGATOR_PRIVATE_KEY \
      --broadcast \
      --skip-simulation \
      --skip "lib/delegation-framework/lib/SCL/**" \
      --skip "lib/delegation-framework/lib/FreshCryptoLib/**" \
      --skip "lib/delegation-framework/lib/FCL/**"

Required env vars: DELEGATOR_PRIVATE_KEY, REDEEMER_PRIVATE_KEY, SIGNER_PRIVATE_KEY, RPC_URL
See .env.example.
