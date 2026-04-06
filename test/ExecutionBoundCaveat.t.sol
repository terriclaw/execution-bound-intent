// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";

contract ExecutionBoundCaveatTest is Test {
    using ExecutionIntentLib for ExecutionIntent;

    ExecutionBoundCaveat caveat;

    uint256 signerKey = 0xA11CE;
    address signer;
    address account  = address(0xACC0);
    address redeemer = address(0xCA11);
    address target   = address(0xBEEF);
    bytes32 domainSep;

    function setUp() public {
        vm.warp(1_000_000);
        caveat = new ExecutionBoundCaveat();
        signer = vm.addr(signerKey);
        domainSep = caveat.DOMAIN_SEPARATOR();
    }

    function _intent(uint256 value, bytes memory data, uint256 nonce, uint256 deadline)
        internal view returns (ExecutionIntent memory)
    {
        return ExecutionIntent({
            account: account, target: target, value: value,
            dataHash: keccak256(data), nonce: nonce, deadline: deadline
        });
    }

    function _sign(ExecutionIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(domainSep));
        return abi.encodePacked(r, s, v);
    }

    function _exec(uint256 value, bytes memory data) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(target, value, data);
    }

    function _hook(ExecutionIntent memory intent, bytes memory sig, bytes memory data, uint256 value) internal {
        caveat.beforeHook("", abi.encode(intent, signer, sig), bytes32(0), _exec(value, data), bytes32(0), account, redeemer);
    }

    function test_exactMatch() public {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", redeemer, 1e18);
        ExecutionIntent memory i = _intent(0, data, 0, 0);
        _hook(i, _sign(i), data, 0);
    }

    function test_nonceConsumed() public {
        bytes memory data = hex"ff";
        ExecutionIntent memory i = _intent(0, data, 42, 0);
        assertFalse(caveat.isNonceUsed(account, signer, 42));
        _hook(i, _sign(i), data, 0);
        assertTrue(caveat.isNonceUsed(account, signer, 42));
    }

    function test_revert_replay() public {
        bytes memory data = hex"01";
        ExecutionIntent memory i = _intent(0, data, 0, 0);
        bytes memory sig = _sign(i);
        _hook(i, sig, data, 0);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.NonceAlreadyUsed.selector, account, signer, 0));
        caveat.beforeHook("", abi.encode(i, signer, sig), bytes32(0), _exec(0, data), bytes32(0), account, redeemer);
    }

    function test_revert_wrongTarget() public {
        bytes memory data = hex"02";
        ExecutionIntent memory i = _intent(0, data, 0, 0);
        bytes memory execData = ExecutionLib.encodeSingle(address(0xDEAD), 0, data);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.TargetMismatch.selector, target, address(0xDEAD)));
        caveat.beforeHook("", abi.encode(i, signer, _sign(i)), bytes32(0), execData, bytes32(0), account, redeemer);
    }

    function test_revert_wrongValue() public {
        bytes memory data = hex"03";
        ExecutionIntent memory i = _intent(1 ether, data, 0, 0);
        bytes memory execData = ExecutionLib.encodeSingle(target, 2 ether, data);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.ValueMismatch.selector, 1 ether, 2 ether));
        caveat.beforeHook("", abi.encode(i, signer, _sign(i)), bytes32(0), execData, bytes32(0), account, redeemer);
    }

    function test_revert_wrongCalldata() public {
        bytes memory signed = hex"aabbccdd";
        bytes memory actual = hex"aabbccde";
        ExecutionIntent memory i = _intent(0, signed, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.DataHashMismatch.selector, keccak256(signed), keccak256(actual)));
        caveat.beforeHook("", abi.encode(i, signer, _sign(i)), bytes32(0), _exec(0, actual), bytes32(0), account, redeemer);
    }

    function test_revert_expired() public {
        bytes memory data = hex"04";
        uint256 deadline = block.timestamp - 1;
        ExecutionIntent memory i = _intent(0, data, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.IntentExpired.selector, deadline, block.timestamp));
        caveat.beforeHook("", abi.encode(i, signer, _sign(i)), bytes32(0), _exec(0, data), bytes32(0), account, redeemer);
    }

    function test_revert_wrongAccount() public {
        bytes memory data = hex"05";
        ExecutionIntent memory i = _intent(0, data, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ExecutionBoundCaveat.AccountMismatch.selector, account, address(0xBAD)));
        caveat.beforeHook("", abi.encode(i, signer, _sign(i)), bytes32(0), _exec(0, data), bytes32(0), address(0xBAD), redeemer);
    }

    function test_revert_wrongSigner() public {
        bytes memory data = hex"06";
        ExecutionIntent memory i = _intent(0, data, 0, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, i.digest(domainSep));
        vm.expectRevert(ExecutionBoundCaveat.InvalidSignature.selector);
        caveat.beforeHook("", abi.encode(i, signer, abi.encodePacked(r, s, v)), bytes32(0), _exec(0, data), bytes32(0), account, redeemer);
    }
}
