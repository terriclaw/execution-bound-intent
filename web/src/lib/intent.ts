import { keccak256, encodeAbiParameters, toHex, concat } from 'viem'

export interface ExecutionIntent {
  account: `0x${string}`
  target: `0x${string}`
  value: bigint
  dataHash: `0x${string}`
  nonce: bigint
  deadline: bigint
}

export interface RunParams {
  account: `0x${string}`
  target: `0x${string}`
  value: bigint
  recipient: `0x${string}`
  amount: bigint
  nonce: bigint
  deadline: bigint
}

export const DOMAIN_NAME = 'ExecutionBoundIntent'
export const DOMAIN_VERSION = '1'
export const CAVEAT_ADDRESS = '0x0000000000000000000000000000000000000001' as `0x${string}`
export const CHAIN_ID = 8453

export const TRANSFER_SELECTOR = '0xa9059cbb'

export function encodeTransfer(recipient: `0x${string}`, amount: bigint): `0x${string}` {
  const encoded = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [recipient, amount]
  )
  return `${TRANSFER_SELECTOR}${encoded.slice(2)}` as `0x${string}`
}

export function buildIntent(params: RunParams): ExecutionIntent {
  const calldata = encodeTransfer(params.recipient, params.amount)
  const dataHash = keccak256(calldata as `0x${string}`)
  return {
    account: params.account,
    target: params.target,
    value: params.value,
    dataHash,
    nonce: params.nonce,
    deadline: params.deadline,
  }
}

export function buildMutatedIntent(params: RunParams): { calldata: `0x${string}`; dataHash: `0x${string}` } {
  const mutatedRecipient = '0x000000000000000000000000000000000000eEeE' as `0x${string}`
  const mutatedAmount = params.amount * 10n
  const calldata = encodeTransfer(mutatedRecipient, mutatedAmount)
  const dataHash = keccak256(calldata)
  return { calldata, dataHash }
}

export function computeIntentDigest(intent: ExecutionIntent): `0x${string}` {
  const typeHash = keccak256(toHex(
    'ExecutionIntent(address account,address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)'
  ))
  const structHash = keccak256(encodeAbiParameters(
    [
      { type: 'bytes32' },
      { type: 'address' },
      { type: 'address' },
      { type: 'uint256' },
      { type: 'bytes32' },
      { type: 'uint256' },
      { type: 'uint256' },
    ],
    [typeHash, intent.account, intent.target, intent.value, intent.dataHash, intent.nonce, intent.deadline]
  ))
  const domainTypeHash = keccak256(toHex(
    'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
  ))
  const domainSep = keccak256(encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
    [
      domainTypeHash,
      keccak256(toHex(DOMAIN_NAME)),
      keccak256(toHex(DOMAIN_VERSION)),
      BigInt(CHAIN_ID),
      CAVEAT_ADDRESS,
    ]
  ))
  return keccak256(concat(['0x1901', domainSep, structHash]))
}

export function simulateSignature(): `0x${string}` {
  return `0x${'ab'.repeat(32)}${'cd'.repeat(32)}1b` as `0x${string}`
}

export function shortHex(hex: string, chars = 8): string {
  if (hex.length <= chars + 4) return hex
  return `${hex.slice(0, chars + 2)}...${hex.slice(-4)}`
}

export function formatAmount(amount: bigint, decimals = 6): string {
  const divisor = 10n ** BigInt(decimals)
  const whole = amount / divisor
  const frac = amount % divisor
  if (frac === 0n) return whole.toString()
  return `${whole}.${frac.toString().padStart(decimals, '0').replace(/0+$/, '')}`
}
