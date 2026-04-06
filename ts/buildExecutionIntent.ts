import { keccak256 } from "viem";

export interface ExecutionIntent {
  account:  `0x${string}`;
  target:   `0x${string}`;
  value:    bigint;
  dataHash: `0x${string}`;
  nonce:    bigint;
  deadline: bigint;
}

export interface ExecutionIntentInput {
  account:  `0x${string}`;
  target:   `0x${string}`;
  value:    bigint;
  calldata: `0x${string}`;
  nonce:    bigint;
  deadline: bigint;
}

export interface BuiltIntent {
  intent: ExecutionIntent;
  dataHash: `0x${string}`;
}

export function buildExecutionIntent(input: ExecutionIntentInput): BuiltIntent {
  const dataHash = keccak256(input.calldata);

  const intent: ExecutionIntent = {
    account:  input.account,
    target:   input.target,
    value:    input.value,
    dataHash,
    nonce:    input.nonce,
    deadline: input.deadline,
  };

  return { intent, dataHash };
}
