/**
 * Reference example: build and sign an ExecutionIntent for an exact ERC-20 transfer.
 *
 * This is a demonstration only — no live network calls.
 * Replace CAVEAT_ENFORCER_ADDRESS and private key with real values to use onchain.
 */

import { createWalletClient, encodeFunctionData, http, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { buildExecutionIntent } from "./buildExecutionIntent.js";
import { signExecutionIntent } from "./signExecutionIntent.js";

// ERC-20 transfer ABI fragment
const erc20Abi = [
  {
    name: "transfer",
    type: "function",
    inputs: [
      { name: "to",     type: "address" },
      { name: "value",  type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

const CAVEAT_ENFORCER_ADDRESS = "0xYourDeployedCaveatEnforcer" as `0x${string}`;
const DELEGATOR_ACCOUNT       = "0xYourSmartAccount"            as `0x${string}`;
const USDC_ADDRESS            = "0xYourUSDCAddress"             as `0x${string}`;
const RECIPIENT               = "0xRecipient"                   as `0x${string}`;

async function main() {
  // 1. Build the exact calldata to commit to
  const calldata = encodeFunctionData({
    abi: erc20Abi,
    functionName: "transfer",
    args: [RECIPIENT, parseUnits("100", 6)],
  });

  // 2. Build the intent — dataHash = keccak256(calldata)
  const { intent } = buildExecutionIntent({
    account:  DELEGATOR_ACCOUNT,
    target:   USDC_ADDRESS,
    value:    0n,
    calldata,
    nonce:    1n,
    deadline: 0n, // no expiry
  });

  console.log("Intent:", intent);

  // 3. Sign via EIP-712
  // Replace with a real private key or wallet
  const account = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
  const wallet  = createWalletClient({ account, chain: base, transport: http() });

  const domain = {
    name:              "ExecutionBoundIntent",
    version:           "1",
    chainId:           base.id,
    verifyingContract: CAVEAT_ENFORCER_ADDRESS,
  };

  const signature = await signExecutionIntent(wallet, intent, domain);

  console.log("Signature:", signature);
  console.log("");
  console.log("Pass to DelegationManager caveat args:");
  console.log("  intent:   ", intent);
  console.log("  signer:   ", account.address);
  console.log("  signature:", signature);
}

main().catch(console.error);
