// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { Delegation, Caveat, ModeCode } from "@delegation-framework/utils/Types.sol";
import { ExecutionBoundCaveat } from "../src/ExecutionBoundCaveat.sol";
import { ExecutionIntent, ExecutionIntentLib } from "../src/libs/ExecutionIntentLib.sol";
import { DemoTarget } from "../src/DemoTarget.sol";

interface IDelegationManager {
    function redeemDelegations(bytes[] calldata, ModeCode[] calldata, bytes[] calldata) external;
    function getDomainHash() external view returns (bytes32);
    function ROOT_AUTHORITY() external view returns (bytes32);
}

/// @title TestnetDemo
/// @notice Level A demo - full DelegationManager redemption path on Sepolia.
///
/// Flow 1: exact execution succeeds (setValue(42))
/// Flow 2: mutated calldata reverts (setValue(999))
/// Flow 3: replay reverts (same nonce)
///
/// Env vars: DELEGATOR_PRIVATE_KEY, REDEEMER_PRIVATE_KEY, SIGNER_PRIVATE_KEY, RPC_URL
///
/// Run:
///   forge script script/TestnetDemo.s.sol --rpc-url $RPC_URL --broadcast -vvvv
///
/// Sepolia v1.3.0:
///   DelegationManager:   0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3
///   HybridDeleGatorImpl: 0x48dBe696A4D990079e039489bA2053B36E8FFEC4

contract TestnetDemo is Script {
    using ExecutionIntentLib for ExecutionIntent;
    using MessageHashUtils for bytes32;

    // Sepolia v1.3.0 deterministic addresses
    address constant DM   = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3;
    address constant IMPL = 0x48dBe696A4D990079e039489bA2053B36E8FFEC4;

    // Delegation typehashes - inlined to avoid SCL transitive imports
    bytes32 constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)Caveat(address enforcer,bytes terms)"
    );
    bytes32 constant CAVEAT_TYPEHASH = keccak256("Caveat(address enforcer,bytes terms)");

    // State shared across helpers
    ExecutionBoundCaveat caveat;
    DemoTarget           target;
    address              delegatorAccount;
    address              signer;

    function run() external {
        uint256 delegatorKey = vm.envUint("DELEGATOR_PRIVATE_KEY");
        uint256 redeemerKey  = vm.envUint("REDEEMER_PRIVATE_KEY");
        uint256 signerKey    = vm.envUint("SIGNER_PRIVATE_KEY");
        signer = vm.addr(signerKey);

        console.log("=== Execution-Bound Intent Testnet Demo ===");
        console.log("DelegationManager:", DM);
        console.log("delegatorEOA:     ", vm.addr(delegatorKey));
        console.log("redeemer:         ", vm.addr(redeemerKey));
        console.log("signer:           ", signer);

        _deploy(delegatorKey);
        _runFlows(delegatorKey, redeemerKey, signerKey);
        _summary();
    }

    function _deploy(uint256 delegatorKey) internal {
        vm.startBroadcast(delegatorKey);
        caveat = new ExecutionBoundCaveat();
        target = new DemoTarget();
        delegatorAccount = address(new ERC1967Proxy(
            IMPL,
            abi.encodeWithSignature(
                "initialize(address,string[],uint256[],uint256[])",
                vm.addr(delegatorKey),
                new string[](0),
                new uint256[](0),
                new uint256[](0)
            )
        ));
        vm.stopBroadcast();
        console.log("ExecutionBoundCaveat:", address(caveat));
        console.log("DemoTarget:          ", address(target));
        console.log("DelegatorAccount:    ", delegatorAccount);
    }

    function _buildDelegation(
        uint256 delegatorKey,
        bytes memory intentArgs
    ) internal view returns (Delegation memory d) {
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(caveat), terms: hex"", args: intentArgs });
        d = Delegation({
            delegate:  vm.addr(vm.envUint("REDEEMER_PRIVATE_KEY")),
            delegator: delegatorAccount,
            authority: IDelegationManager(DM).ROOT_AUTHORITY(),
            caveats:   caveats,
            salt:      0,
            signature: hex""
        });
        // Sign delegation
        bytes32[] memory ch = new bytes32[](1);
        ch[0] = keccak256(abi.encode(CAVEAT_TYPEHASH, caveats[0].enforcer, keccak256(caveats[0].terms)));
        bytes32 dHash = keccak256(abi.encode(
            DELEGATION_TYPEHASH, d.delegate, d.delegator, d.authority,
            keccak256(abi.encodePacked(ch)), d.salt
        ));
        bytes32 tHash = dHash.toTypedDataHash(IDelegationManager(DM).getDomainHash());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorKey, tHash);
        d.signature = abi.encodePacked(r, s, v);
    }

    function _redeem(uint256 redeemerKey, Delegation memory d, bytes memory execCd) internal {
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        bytes[] memory pc = new bytes[](1);
        pc[0] = abi.encode(ds);
        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory ecd = new bytes[](1);
        ecd[0] = execCd;
        vm.startBroadcast(redeemerKey);
        IDelegationManager(DM).redeemDelegations(pc, modes, ecd);
        vm.stopBroadcast();
    }

    function _signIntent(uint256 signerKey, bytes memory cd) internal view returns (bytes memory) {
        ExecutionIntent memory intent = ExecutionIntent({
            account:  delegatorAccount,
            target:   address(target),
            value:    0,
            dataHash: keccak256(cd),
            nonce:    0,
            deadline: 0
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, intent.digest(caveat.DOMAIN_SEPARATOR()));
        return abi.encode(intent, signer, abi.encodePacked(r, s, v));
    }

    function _flow1(uint256 delegatorKey, uint256 redeemerKey, bytes memory intentArgs) internal {
        console.log("");
        console.log("--- Flow 1: Exact Execution ---");
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        Delegation memory d = _buildDelegation(delegatorKey, intentArgs);
        _redeem(redeemerKey, d, ExecutionLib.encodeSingle(address(target), 0, cd));
        console.log("Flow 1: SUCCESS - target.value():", target.value());
    }

    function _flow2(uint256 delegatorKey, uint256 redeemerKey, bytes memory intentArgs) internal {
        console.log("");
        console.log("--- Flow 2: Mutated Execution (expect revert) ---");
        bytes memory mutCd = abi.encodeWithSignature("setValue(uint256)", 999);
        Delegation memory d = _buildDelegation(delegatorKey, intentArgs);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        bytes[] memory pc = new bytes[](1);
        pc[0] = abi.encode(ds);
        ModeCode[] memory m = new ModeCode[](1);
        m[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory ecd = new bytes[](1);
        ecd[0] = ExecutionLib.encodeSingle(address(target), 0, mutCd);
        vm.startBroadcast(redeemerKey);
        try IDelegationManager(DM).redeemDelegations(pc, m, ecd) {
            console.log("Flow 2: UNEXPECTED SUCCESS");
        } catch {
            console.log("Flow 2: REVERTED as expected (DataHashMismatch)");
        }
        vm.stopBroadcast();
    }

    function _flow3(uint256 delegatorKey, uint256 redeemerKey, bytes memory intentArgs) internal {
        console.log("");
        console.log("--- Flow 3: Replay (expect revert) ---");
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        Delegation memory d = _buildDelegation(delegatorKey, intentArgs);
        Delegation[] memory ds = new Delegation[](1);
        ds[0] = d;
        bytes[] memory pc = new bytes[](1);
        pc[0] = abi.encode(ds);
        ModeCode[] memory m = new ModeCode[](1);
        m[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory ecd = new bytes[](1);
        ecd[0] = ExecutionLib.encodeSingle(address(target), 0, cd);
        vm.startBroadcast(redeemerKey);
        try IDelegationManager(DM).redeemDelegations(pc, m, ecd) {
            console.log("Flow 3: UNEXPECTED SUCCESS");
        } catch {
            console.log("Flow 3: REVERTED as expected (NonceAlreadyUsed)");
        }
        vm.stopBroadcast();
    }

    function _runFlows(uint256 delegatorKey, uint256 redeemerKey, uint256 signerKey) internal {
        bytes memory cd = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes memory intentArgs = _signIntent(signerKey, cd);
        _flow1(delegatorKey, redeemerKey, intentArgs);
        _flow2(delegatorKey, redeemerKey, intentArgs);
        _flow3(delegatorKey, redeemerKey, intentArgs);
    }

    function _summary() internal view {
        console.log("");
        console.log("=== Summary ===");
        console.log("target.value():       ", target.value());
        console.log("nonce 0 consumed:     ", caveat.isNonceUsed(delegatorAccount, signer, 0));
        console.log("ExecutionBoundCaveat: ", address(caveat));
        console.log("DemoTarget:           ", address(target));
        console.log("DelegatorAccount:     ", delegatorAccount);
    }
}
