import { type WalletClient } from "viem";
import { type ExecutionIntent } from "./buildExecutionIntent.js";

export const EXECUTION_INTENT_TYPES = {
  ExecutionIntent: [
    { name: "account",  type: "address" },
    { name: "target",   type: "address" },
    { name: "value",    type: "uint256" },
    { name: "dataHash", type: "bytes32" },
    { name: "nonce",    type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface Domain {
  name:              string;
  version:           string;
  chainId:           number;
  verifyingContract: `0x${string}`;
}

export async function signExecutionIntent(
  wallet: WalletClient,
  intent: ExecutionIntent,
  domain: Domain,
): Promise<`0x${string}`> {
  const account = wallet.account;
  if (!account) throw new Error("No account on wallet client");

  return wallet.signTypedData({
    account,
    domain,
    types: EXECUTION_INTENT_TYPES,
    primaryType: "ExecutionIntent",
    message: intent,
  });
}
