import { useState, useEffect, useCallback } from 'react'
import {
  buildIntent, buildMutatedIntent, computeIntentDigest, simulateSignature,
  encodeTransfer, shortHex, formatAmount,
  type RunParams,
} from './lib/intent.js'

const DEFAULT_PARAMS: RunParams = {
  account:   '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
  target:    '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
  value:     0n,
  recipient: '0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B',
  amount:    100_000_000n,
  nonce:     1n,
  deadline:  0n,
}

type StepId = 'intent' | 'hash' | 'sign' | 'encode' | 'redeem' | 'outcome'

const STEPS: { id: StepId; label: string }[] = [
  { id: 'intent',  label: 'Build Intent' },
  { id: 'hash',    label: 'Hash Calldata' },
  { id: 'sign',    label: 'Sign EIP-712' },
  { id: 'encode',  label: 'Encode Args' },
  { id: 'redeem',  label: 'Redeem' },
  { id: 'outcome', label: 'Outcome' },
]

function Tag({ children, color = 'green' }: { children: React.ReactNode; color?: 'green' | 'red' | 'blue' | 'yellow' }) {
  const colors = {
    green:  'bg-emerald-950 text-emerald-400 border-emerald-800',
    red:    'bg-red-950 text-red-400 border-red-800',
    blue:   'bg-blue-950 text-blue-400 border-blue-800',
    yellow: 'bg-yellow-950 text-yellow-400 border-yellow-800',
  }
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded border text-xs font-mono ${colors[color]}`}>
      {children}
    </span>
  )
}

function DataRow({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    navigator.clipboard.writeText(value)
    setCopied(true)
    setTimeout(() => setCopied(false), 1200)
  }
  return (
    <div className={`flex items-start gap-3 py-2 border-b border-zinc-800 last:border-0 ${highlight ? 'bg-zinc-800/40 -mx-3 px-3 rounded' : ''}`}>
      <span className="text-zinc-500 text-xs font-mono w-28 shrink-0 pt-0.5">{label}</span>
      <span className="text-zinc-200 text-xs font-mono break-all flex-1">{value}</span>
      <button onClick={copy} className="text-zinc-600 hover:text-zinc-300 text-xs shrink-0 transition-colors">
        {copied ? 'ok' : 'copy'}
      </button>
    </div>
  )
}

function Card({ title, children, variant = 'default' }: {
  title: React.ReactNode
  children: React.ReactNode
  variant?: 'default' | 'success' | 'failure'
}) {
  const borders = { default: 'border-zinc-700', success: 'border-emerald-700', failure: 'border-red-700' }
  const headers = { default: 'bg-zinc-800/60', success: 'bg-emerald-950/60', failure: 'bg-red-950/60' }
  return (
    <div className={`rounded-lg border ${borders[variant]} overflow-hidden`}>
      <div className={`px-4 py-2.5 ${headers[variant]} border-b ${borders[variant]}`}>
        <div className="text-xs font-mono font-medium text-zinc-300">{title}</div>
      </div>
      <div className="px-4 py-3 bg-zinc-900/60">{children}</div>
    </div>
  )
}

function StepBadge({ step, current, done }: { step: number; current: boolean; done: boolean }) {
  if (done) return <div className="w-7 h-7 rounded-full bg-emerald-900 border border-emerald-600 flex items-center justify-center text-emerald-400 text-xs">ok</div>
  if (current) return <div className="w-7 h-7 rounded-full bg-zinc-700 border-2 border-zinc-300 flex items-center justify-center text-zinc-100 text-xs font-mono font-bold">{step}</div>
  return <div className="w-7 h-7 rounded-full bg-zinc-900 border border-zinc-700 flex items-center justify-center text-zinc-600 text-xs font-mono">{step}</div>
}

export default function App() {
  const [params, setParams] = useState<RunParams>(DEFAULT_PARAMS)
  const [currentStep, setCurrentStep] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [hasRun, setHasRun] = useState(false)
  const [savedRun, setSavedRun] = useState<RunParams | null>(null)
  const [showCustom, setShowCustom] = useState(false)
  const [customRecipient, setCustomRecipient] = useState('')
  const [customAmount, setCustomAmount] = useState('')
  const [customNonce, setCustomNonce] = useState('')

  const intent = buildIntent(params)
  const calldata = encodeTransfer(params.recipient, params.amount)
  const mutated = buildMutatedIntent(params)
  const digest = computeIntentDigest(intent)
  const signature = simulateSignature()

  const stepIndex = currentStep
  const stepId = STEPS[Math.min(stepIndex, STEPS.length - 1)].id

  useEffect(() => {
    if (!playing) return
    if (currentStep >= STEPS.length - 1) { setPlaying(false); return }
    const t = setTimeout(() => setCurrentStep(s => s + 1), 1400)
    return () => clearTimeout(t)
  }, [playing, currentStep])

  const runDemo = useCallback(() => {
    setCurrentStep(0)
    setPlaying(true)
    setHasRun(true)
    setSavedRun(params)
  }, [params])

  const replayLast = useCallback(() => {
    if (!savedRun) return
    setParams(savedRun)
    setCurrentStep(0)
    setPlaying(true)
  }, [savedRun])

  const applyCustom = () => {
    const p = { ...params }
    if (customRecipient.startsWith('0x')) p.recipient = customRecipient as `0x${string}`
    if (customAmount) p.amount = BigInt(Math.floor(parseFloat(customAmount) * 1_000_000))
    if (customNonce) p.nonce = BigInt(customNonce)
    setParams(p)
    setShowCustom(false)
    setCurrentStep(0)
    setPlaying(false)
    setHasRun(false)
  }

  const isActive = (id: StepId) => STEPS.findIndex(s => s.id === id) === stepIndex
  const isReached = (id: StepId) => STEPS.findIndex(s => s.id === id) <= stepIndex

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100" style={{ fontFamily: "'IBM Plex Sans', sans-serif" }}>

      <div className="border-b border-zinc-800 bg-zinc-950/90 sticky top-0 z-50 backdrop-blur">
        <div className="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
          <div>
            <div className="text-sm font-mono font-semibold text-zinc-100 tracking-tight">execution-bound-intent</div>
            <div className="text-xs text-zinc-500 font-mono mt-0.5">exact execution or revert</div>
          </div>
          <a href="https://github.com/terriclaw/execution-bound-intent" target="_blank" rel="noopener noreferrer"
            className="text-xs font-mono text-zinc-400 hover:text-zinc-100 transition-colors border border-zinc-700 hover:border-zinc-500 px-3 py-1.5 rounded">
            GitHub
          </a>
        </div>
      </div>

      <div className="max-w-6xl mx-auto px-6 py-12">

        <div className="mb-14">
          <div className="inline-block mb-4"><Tag color="blue">terminal enforcement primitive</Tag></div>
          <h1 className="text-3xl font-mono font-semibold text-zinc-50 mb-3 tracking-tight">
            A signed execution is valid only if<br />the actual delegated call matches exactly.
          </h1>
          <p className="text-zinc-400 text-sm max-w-2xl leading-relaxed">
            Policy-based caveats ask "is this allowed?" — they check selectors, targets, value ranges.
            A relayer can still mutate calldata within those bounds.{' '}
            <span className="text-zinc-200">execution-bound-intent enforces exact calldata equality at redemption time.</span>{' '}
            Any deviation reverts.
          </p>
        </div>

        <div className="mb-10">
          <div className="flex items-center gap-0 mb-8">
            {STEPS.map((step, i) => (
              <div key={step.id} className="flex items-center">
                <button onClick={() => { setCurrentStep(i); setPlaying(false) }} className="flex flex-col items-center gap-1.5">
                  <StepBadge step={i + 1} current={i === stepIndex} done={i < stepIndex} />
                  <span className={`text-xs font-mono transition-colors ${i === stepIndex ? 'text-zinc-100' : i < stepIndex ? 'text-emerald-500' : 'text-zinc-600'}`}>
                    {step.label}
                  </span>
                </button>
                {i < STEPS.length - 1 && (
                  <div className={`w-12 h-px mx-2 mb-4 transition-colors ${i < stepIndex ? 'bg-emerald-800' : 'bg-zinc-800'}`} />
                )}
              </div>
            ))}
          </div>

          <div className="flex items-center gap-3">
            <button onClick={runDemo} className="px-4 py-2 bg-zinc-100 text-zinc-900 text-xs font-mono font-semibold rounded hover:bg-white transition-colors">
              Run Demo
            </button>
            <button onClick={() => { setPlaying(false); setCurrentStep(s => Math.max(0, s - 1)) }}
              className="px-3 py-2 border border-zinc-700 text-zinc-400 text-xs font-mono rounded hover:border-zinc-500 hover:text-zinc-200 transition-colors">
              Prev
            </button>
            <button onClick={() => { setPlaying(false); setCurrentStep(s => Math.min(STEPS.length - 1, s + 1)) }}
              className="px-3 py-2 border border-zinc-700 text-zinc-400 text-xs font-mono rounded hover:border-zinc-500 hover:text-zinc-200 transition-colors">
              Next
            </button>
            {hasRun && (
              <button onClick={replayLast} className="px-3 py-2 border border-zinc-700 text-zinc-400 text-xs font-mono rounded hover:border-zinc-500 hover:text-zinc-200 transition-colors">
                Replay Last
              </button>
            )}
            <button onClick={() => setShowCustom(!showCustom)}
              className="px-3 py-2 border border-zinc-700 text-zinc-400 text-xs font-mono rounded hover:border-zinc-500 hover:text-zinc-200 transition-colors ml-auto">
              Custom Params
            </button>
          </div>

          {showCustom && (
            <div className="mt-4 p-4 border border-zinc-700 rounded-lg bg-zinc-900">
              <div className="text-xs font-mono text-zinc-400 mb-3">Custom Parameters</div>
              <div className="grid grid-cols-3 gap-3">
                <div>
                  <label className="text-xs text-zinc-500 font-mono mb-1 block">recipient</label>
                  <input value={customRecipient} onChange={e => setCustomRecipient(e.target.value)} placeholder="0x..."
                    className="w-full bg-zinc-800 border border-zinc-700 rounded px-2 py-1.5 text-xs font-mono text-zinc-200 focus:outline-none focus:border-zinc-500" />
                </div>
                <div>
                  <label className="text-xs text-zinc-500 font-mono mb-1 block">amount (USDC)</label>
                  <input value={customAmount} onChange={e => setCustomAmount(e.target.value)} placeholder="100"
                    className="w-full bg-zinc-800 border border-zinc-700 rounded px-2 py-1.5 text-xs font-mono text-zinc-200 focus:outline-none focus:border-zinc-500" />
                </div>
                <div>
                  <label className="text-xs text-zinc-500 font-mono mb-1 block">nonce</label>
                  <input value={customNonce} onChange={e => setCustomNonce(e.target.value)} placeholder="1"
                    className="w-full bg-zinc-800 border border-zinc-700 rounded px-2 py-1.5 text-xs font-mono text-zinc-200 focus:outline-none focus:border-zinc-500" />
                </div>
              </div>
              <button onClick={applyCustom} className="mt-3 px-3 py-1.5 bg-zinc-700 text-zinc-100 text-xs font-mono rounded hover:bg-zinc-600 transition-colors">
                Apply
              </button>
            </div>
          )}
        </div>

        <div className="space-y-6">

          {isReached('intent') && (
            <div className={`transition-opacity duration-300 ${isActive('intent') ? 'opacity-100' : 'opacity-70'}`}>
              <Card title={<span><span className="text-zinc-500">01 /</span> Build ExecutionIntent</span>}>
                <p className="text-xs text-zinc-400 mb-4">
                  The signer commits to an exact execution. All fields are included in the signed EIP-712 message.
                  The signer may differ from the delegating account.
                </p>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <div className="text-xs font-mono text-zinc-500 mb-2">struct ExecutionIntent</div>
                    <DataRow label="account" value={shortHex(params.account)} />
                    <DataRow label="target" value={shortHex(params.target)} />
                    <DataRow label="value" value={params.value.toString()} />
                    <DataRow label="nonce" value={params.nonce.toString()} />
                    <DataRow label="deadline" value={params.deadline === 0n ? '0 (no expiry)' : params.deadline.toString()} />
                  </div>
                  <div>
                    <div className="text-xs font-mono text-zinc-500 mb-2">calldata to commit</div>
                    <DataRow label="function" value="transfer(address,uint256)" />
                    <DataRow label="recipient" value={shortHex(params.recipient)} />
                    <DataRow label="amount" value={`${formatAmount(params.amount)} USDC`} />
                    <DataRow label="raw" value={shortHex(calldata, 12)} />
                  </div>
                </div>
              </Card>
            </div>
          )}

          {isReached('hash') && (
            <div className={`transition-opacity duration-300 ${isActive('hash') ? 'opacity-100' : 'opacity-70'}`}>
              <Card title={<span><span className="text-zinc-500">02 /</span> Hash Calldata</span>}>
                <p className="text-xs text-zinc-400 mb-4">
                  dataHash = keccak256(calldata) — binds the full function selector and all arguments.
                  target and value are committed separately.
                </p>
                <DataRow label="calldata" value={shortHex(calldata, 16)} />
                <DataRow label="dataHash" value={intent.dataHash} highlight />
                <div className="mt-3 p-2 bg-zinc-800/60 rounded text-xs font-mono text-zinc-400">
                  Any byte change produces a different hash and causes revert.
                </div>
              </Card>
            </div>
          )}

          {isReached('sign') && (
            <div className={`transition-opacity duration-300 ${isActive('sign') ? 'opacity-100' : 'opacity-70'}`}>
              <Card title={<span><span className="text-zinc-500">03 /</span> Sign EIP-712 Digest</span>}>
                <p className="text-xs text-zinc-400 mb-4">
                  The signer signs an EIP-712 typed data digest. Domain binds chainId and verifyingContract.
                  Signatures are not portable across deployments or chains.
                </p>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <div className="text-xs font-mono text-zinc-500 mb-2">domain</div>
                    <DataRow label="name" value="ExecutionBoundIntent" />
                    <DataRow label="version" value="1" />
                    <DataRow label="chainId" value="8453 (Base)" />
                    <DataRow label="contract" value="ExecutionBoundCaveat" />
                  </div>
                  <div>
                    <div className="text-xs font-mono text-zinc-500 mb-2">output</div>
                    <DataRow label="digest" value={shortHex(digest)} highlight />
                    <DataRow label="signature" value={shortHex(signature, 12)} />
                    <div className="mt-2 text-xs text-zinc-500 font-mono">EOA or ERC-1271 valid</div>
                  </div>
                </div>
              </Card>
            </div>
          )}

          {isReached('encode') && (
            <div className={`transition-opacity duration-300 ${isActive('encode') ? 'opacity-100' : 'opacity-70'}`}>
              <Card title={<span><span className="text-zinc-500">04 /</span> Encode Caveat Args</span>}>
                <p className="text-xs text-zinc-400 mb-4">
                  The signed intent, signer address, and signature are ABI-encoded as caveat args.
                  Passed to DelegationManager at redemption. terms are unused in v1.
                </p>
                <DataRow label="encoding" value="abi.encode(ExecutionIntent, address signer, bytes signature)" />
                <DataRow label="terms" value="0x (ignored in v1)" />
                <div className="mt-3 p-2 bg-zinc-800/60 rounded text-xs font-mono text-zinc-400">
                  signer may differ from delegator<br />
                  signature must recover to signer (EOA or ERC-1271)
                </div>
              </Card>
            </div>
          )}

          {isReached('redeem') && (
            <div className={`transition-opacity duration-300 ${isActive('redeem') ? 'opacity-100' : 'opacity-70'}`}>
              <div className="grid grid-cols-2 gap-4">
                <Card title={<span className="text-emerald-400">05 / Exact Execution</span>} variant="success">
                  <p className="text-xs text-zinc-400 mb-4">Caveat decodes execution and checks every field.</p>
                  <DataRow label="mode" value="CALLTYPE_SINGLE (0x00)" />
                  <DataRow label="target" value={shortHex(params.target)} />
                  <DataRow label="value" value="0" />
                  <DataRow label="calldata" value={shortHex(calldata, 12)} />
                  <DataRow label="computed hash" value={shortHex(intent.dataHash)} />
                  <DataRow label="committed hash" value={shortHex(intent.dataHash)} />
                  <div className="mt-3 space-y-1">
                    {['account == _delegator', 'target matches', 'value matches', 'dataHash matches', 'deadline valid', 'nonce unused', 'signature valid'].map(c => (
                      <div key={c} className="flex items-center gap-2 text-xs font-mono">
                        <span className="text-emerald-400">ok</span>
                        <span className="text-zinc-300">{c}</span>
                      </div>
                    ))}
                  </div>
                </Card>

                <Card title={<span className="text-red-400">05 / Mutated Execution</span>} variant="failure">
                  <p className="text-xs text-zinc-400 mb-4">Same signed intent. Relayer mutates calldata.</p>
                  <DataRow label="mode" value="CALLTYPE_SINGLE (0x00)" />
                  <DataRow label="target" value={shortHex(params.target)} />
                  <DataRow label="value" value="0" />
                  <DataRow label="calldata" value={shortHex(mutated.calldata, 12)} />
                  <DataRow label="computed hash" value={shortHex(mutated.dataHash)} />
                  <DataRow label="committed hash" value={shortHex(intent.dataHash)} />
                  <div className="mt-3 space-y-1">
                    {['account == _delegator', 'target matches', 'value matches'].map(c => (
                      <div key={c} className="flex items-center gap-2 text-xs font-mono">
                        <span className="text-emerald-400">ok</span>
                        <span className="text-zinc-300">{c}</span>
                      </div>
                    ))}
                    <div className="flex items-center gap-2 text-xs font-mono">
                      <span className="text-red-400">fail</span>
                      <span className="text-red-300 font-semibold">DataHashMismatch revert</span>
                    </div>
                  </div>
                </Card>
              </div>

              <div className="mt-4 p-4 border border-zinc-700 rounded-lg bg-zinc-900">
                <div className="text-xs font-mono text-zinc-500 mb-3">calldata diff</div>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <div className="text-xs text-emerald-500 font-mono mb-1">signed (passes)</div>
                    <div className="text-xs font-mono text-zinc-300 bg-zinc-800 p-2 rounded">
                      transfer(<span className="text-emerald-300">{shortHex(params.recipient)}</span>, <span className="text-emerald-300">{formatAmount(params.amount)} USDC</span>)
                    </div>
                  </div>
                  <div>
                    <div className="text-xs text-red-500 font-mono mb-1">mutated (reverts)</div>
                    <div className="text-xs font-mono text-zinc-300 bg-zinc-800 p-2 rounded">
                      transfer(<span className="text-red-300">0x...EEee</span>, <span className="text-red-300">{formatAmount(params.amount * 10n)} USDC</span>)
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}

          {isReached('outcome') && (
            <div className={`transition-opacity duration-300 ${isActive('outcome') ? 'opacity-100' : 'opacity-70'}`}>
              <div className="grid grid-cols-2 gap-4">
                <Card title="Exact execution -> success" variant="success">
                  <div className="text-center py-4">
                    <div className="text-emerald-400 font-mono text-sm font-semibold mb-2">Nonce consumed. Execution proceeds.</div>
                    <div className="text-xs text-zinc-500 font-mono">
                      transfer({shortHex(params.recipient)}, {formatAmount(params.amount)} USDC) executed
                    </div>
                  </div>
                </Card>
                <Card title="Mutated execution -> revert" variant="failure">
                  <div className="text-center py-4">
                    <div className="text-red-400 font-mono text-sm font-semibold mb-2">DataHashMismatch revert</div>
                    <div className="text-xs text-zinc-500 font-mono break-all">
                      committed: {shortHex(intent.dataHash)}<br />
                      executed:  {shortHex(mutated.dataHash)}
                    </div>
                  </div>
                </Card>
              </div>
            </div>
          )}

        </div>

        <div className="mt-16 pt-12 border-t border-zinc-800">
          <h2 className="text-xs font-mono font-semibold text-zinc-500 mb-6 uppercase tracking-widest">Reference</h2>
          <div className="grid grid-cols-3 gap-6">
            <Card title="ExecutionIntent struct">
              <div className="text-xs font-mono text-zinc-400 space-y-1">
                <div><span className="text-blue-400">address</span> <span className="text-zinc-200">account</span></div>
                <div><span className="text-blue-400">address</span> <span className="text-zinc-200">target</span></div>
                <div><span className="text-blue-400">uint256</span> <span className="text-zinc-200">value</span></div>
                <div><span className="text-blue-400">bytes32</span> <span className="text-zinc-200">dataHash</span></div>
                <div><span className="text-blue-400">uint256</span> <span className="text-zinc-200">nonce</span></div>
                <div><span className="text-blue-400">uint256</span> <span className="text-zinc-200">deadline</span></div>
              </div>
              <div className="mt-3 text-xs text-zinc-500 font-mono">All fields signed. All fields binding.</div>
            </Card>

            <Card title="Invariant">
              <div className="text-xs font-mono space-y-1">
                <div className="text-zinc-400">keccak256(execution.callData)</div>
                <div className="text-zinc-600 pl-3">== intent.dataHash</div>
                <div className="text-zinc-400">AND execution.target</div>
                <div className="text-zinc-600 pl-3">== intent.target</div>
                <div className="text-zinc-400">AND execution.value</div>
                <div className="text-zinc-600 pl-3">== intent.value</div>
                <div className="text-zinc-400">AND _delegator</div>
                <div className="text-zinc-600 pl-3">== intent.account</div>
              </div>
              <div className="mt-3 text-xs text-zinc-500 font-mono">Any transformation reverts.</div>
            </Card>

            <Card title="Threat model">
              <div className="space-y-1.5">
                {[
                  ['calldata mutation', 'blocked'],
                  ['target substitution', 'blocked'],
                  ['cross-chain replay', 'blocked'],
                  ['intent replay', 'blocked'],
                  ['delegatecall', 'rejected'],
                  ['signer compromise', 'not prevented'],
                  ['front-running', 'not prevented'],
                ].map(([threat, status]) => (
                  <div key={threat} className="flex items-center justify-between text-xs font-mono">
                    <span className="text-zinc-400">{threat}</span>
                    <Tag color={status === 'blocked' || status === 'rejected' ? 'green' : 'yellow'}>{status}</Tag>
                  </div>
                ))}
              </div>
            </Card>
          </div>
        </div>

        <div className="mt-16 pt-8 border-t border-zinc-800 flex items-center justify-between">
          <div className="text-xs font-mono text-zinc-600">
            execution-bound-intent — terminal enforcement primitive for delegated execution
          </div>
          <div className="flex items-center gap-4">
            <a href="https://github.com/terriclaw/execution-bound-intent/blob/master/ERC.md"
              target="_blank" rel="noopener noreferrer"
              className="text-xs font-mono text-zinc-500 hover:text-zinc-300 transition-colors">ERC draft</a>
            <a href="https://github.com/terriclaw/execution-bound-intent/blob/master/INTEGRATION.md"
              target="_blank" rel="noopener noreferrer"
              className="text-xs font-mono text-zinc-500 hover:text-zinc-300 transition-colors">Integration guide</a>
          </div>
        </div>

      </div>
    </div>
  )
}
