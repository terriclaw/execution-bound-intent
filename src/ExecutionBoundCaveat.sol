// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ExecutionIntent, ExecutionIntentLib } from "./libs/ExecutionIntentLib.sol";

struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

contract ExecutionBoundCaveat {
    using ExecutionIntentLib for ExecutionIntent;

    bytes32 public immutable DOMAIN_SEPARATOR;

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    mapping(address account => mapping(address signer => mapping(uint256 nonce => bool))) public usedNonces;

    event NonceConsumed(address indexed account, address indexed signer, uint256 nonce);

    error AccountMismatch(address intentAccount, address delegator);
    error TargetMismatch(address intentTarget, address executionTarget);
    error ValueMismatch(uint256 intentValue, uint256 executionValue);
    error DataHashMismatch(bytes32 intentDataHash, bytes32 executionDataHash);
    error IntentExpired(uint256 deadline, uint256 blockTimestamp);
    error NonceAlreadyUsed(address account, address signer, uint256 nonce);
    error InvalidSignature();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("ExecutionBoundIntent"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        Execution calldata _execution,
        address _delegator,
        address _redeemer,
        bytes32 _delegationHash
    ) external {
        (_terms, _redeemer, _delegationHash);

        (ExecutionIntent memory intent, address signer, bytes memory signature) =
            abi.decode(_args, (ExecutionIntent, address, bytes));

        if (intent.account != _delegator)
            revert AccountMismatch(intent.account, _delegator);

        if (intent.target != _execution.target)
            revert TargetMismatch(intent.target, _execution.target);

        if (intent.value != _execution.value)
            revert ValueMismatch(intent.value, _execution.value);

        bytes32 executionDataHash = keccak256(_execution.callData);
        if (intent.dataHash != executionDataHash)
            revert DataHashMismatch(intent.dataHash, executionDataHash);

        if (intent.deadline != 0 && block.timestamp > intent.deadline)
            revert IntentExpired(intent.deadline, block.timestamp);

        if (usedNonces[intent.account][signer][intent.nonce])
            revert NonceAlreadyUsed(intent.account, signer, intent.nonce);

        if (!SignatureChecker.isValidSignatureNow(signer, intent.digest(DOMAIN_SEPARATOR), signature))
            revert InvalidSignature();

        usedNonces[intent.account][signer][intent.nonce] = true;
        emit NonceConsumed(intent.account, signer, intent.nonce);
    }

    function intentDigest(ExecutionIntent calldata intent) external view returns (bytes32) {
        return intent.digest(DOMAIN_SEPARATOR);
    }

    function isNonceUsed(address account, address signer, uint256 nonce)
        external view returns (bool)
    {
        return usedNonces[account][signer][nonce];
    }
}
