// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

contract SelectorOnlyEnforcer {
    function beforeHook(bytes calldata _terms, bytes calldata, bytes32, bytes calldata _executionCalldata, bytes32, address, address) external pure {
        (, , bytes memory callData) = ExecutionLib.decodeSingle(_executionCalldata);
        bytes4 selector;
        assembly { selector := mload(add(callData, 32)) }
        require(selector == bytes4(_terms[0:4]), "selector mismatch");
    }
}

contract GasBenchmarks is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat  boundCaveat;
    SelectorOnlyEnforcer  selectorOnly;

    uint256 signerKey = 0xA11CE;
    address signer;
    address account  = address(0xACC0);
    address target   = address(0xBEEF);
    address redeemer = address(0xCA11);
    bytes32 domainSep;

    bytes4 constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    function setUp() public {
        vm.warp(1_000_000);
        boundCaveat  = new ExecutionBoundCaveat();
        selectorOnly = new SelectorOnlyEnforcer();
        signer       = vm.addr(signerKey);
        domainSep    = boundCaveat.DOMAIN_SEPARATOR();
    }

    function _smallCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(TRANSFER_SELECTOR, redeemer, 100e6);
    }

    function _mediumCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(keccak256("multiTransfer(address,uint256,address,uint256,address,uint256,address,uint256,address,uint256)")),
            address(0x1), 1e6, address(0x2), 2e6, address(0x3), 3e6, address(0x4), 4e6, address(0x5), 5e6
        );
    }

    function _largeCalldata() internal pure returns (bytes memory) {
        bytes memory data = new bytes(256);
        data[0] = 0xaa; data[1] = 0xbb; data[2] = 0xcc; data[3] = 0xdd;
        return data;
    }

    function _sign(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        return abi.encodePacked(r, s, v);
    }

    function _intent(bytes memory calldata_, uint256 nonce) internal view returns (ExecutionIntent memory) {
        return ExecutionIntent({ account: account, target: target, value: 0, dataHash: keccak256(calldata_), nonce: nonce, deadline: 0 });
    }

    function _hookBound(bytes memory calldata_, uint256 nonce) internal {
        ExecutionIntent memory intent = _intent(calldata_, nonce);
        boundCaveat.beforeHook("", abi.encode(intent, signer, _sign(intent)), bytes32(0), ExecutionLib.encodeSingle(target, 0, calldata_), bytes32(0), account, redeemer);
    }

    function _hookSelector(bytes memory calldata_) internal view {
        selectorOnly.beforeHook(abi.encodePacked(bytes4(calldata_)), "", bytes32(0), ExecutionLib.encodeSingle(target, 0, calldata_), bytes32(0), account, redeemer);
    }

    function test_gas_bound_smallCalldata() public { _hookBound(_smallCalldata(), 0); }
    function test_gas_bound_mediumCalldata() public { _hookBound(_mediumCalldata(), 1); }
    function test_gas_bound_largeCalldata() public { _hookBound(_largeCalldata(), 2); }
    function test_gas_selector_smallCalldata() public { _hookSelector(_smallCalldata()); }
    function test_gas_selector_mediumCalldata() public { _hookSelector(_mediumCalldata()); }
    function test_gas_selector_largeCalldata() public { _hookSelector(_largeCalldata()); }
}
