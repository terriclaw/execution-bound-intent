// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ExecutionIntent, ExecutionIntentLib } from "./libs/ExecutionIntentLib.sol";

/// @title ExecutionBoundCaveat
/// @notice Equality-based caveat enforcer compatible with ERC-7710 / MetaMask delegation framework.
/// @dev beforeHook signature matches ICaveatEnforcer from the MM delegation framework.
///      ModeCode is accepted but not inspected — this enforcer only supports single call type.
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

    /// @notice Called by DelegationManager before execution.
    /// @param _terms    Unused in v1. Pass empty bytes.
    /// @param _args     abi.encode(ExecutionIntent intent, address signer, bytes signature)
    /// @param _executionCalldata  Packed execution: abi.encodePacked(target, value, calldata)
    /// @param _delegator   The delegating smart account. Must match intent.account.
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        bytes32,
        bytes calldata _executionCalldata,
        bytes32,
        address _delegator,
        address
    ) external {
        (_terms);

        (ExecutionIntent memory intent, address signer, bytes memory signature) =
            abi.decode(_args, (ExecutionIntent, address, bytes));

        (address target, uint256 value, bytes calldata callData) =
            ExecutionLib.decodeSingle(_executionCalldata);

        if (intent.account != _delegator)
            revert AccountMismatch(intent.account, _delegator);

        if (intent.target != target)
            revert TargetMismatch(intent.target, target);

        if (intent.value != value)
            revert ValueMismatch(intent.value, value);

        bytes32 executionDataHash = keccak256(callData);
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
