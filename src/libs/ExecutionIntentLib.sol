// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct ExecutionIntent {
    address account;
    address target;
    uint256 value;
    bytes32 dataHash;
    uint256 nonce;
    uint256 deadline;
}

library ExecutionIntentLib {
    bytes32 internal constant EXECUTION_INTENT_TYPEHASH = keccak256(
        "ExecutionIntent(address account,address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)"
    );

    function hashIntent(ExecutionIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXECUTION_INTENT_TYPEHASH,
                intent.account,
                intent.target,
                intent.value,
                intent.dataHash,
                intent.nonce,
                intent.deadline
            )
        );
    }

    function digest(ExecutionIntent memory intent, bytes32 domainSep)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("\x19\x01", domainSep, hashIntent(intent)));
    }

    function hashCalldata(bytes memory data) internal pure returns (bytes32) {
        return keccak256(data);
    }
}
