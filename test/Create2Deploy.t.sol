// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentQuestBoard} from "../src/AgentQuestBoard.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";

/// @notice Validates the baw deploy path.
///
/// @dev `baw contract-call` requires a `--to` address, so a bare contract
///      creation transaction is impossible through the agentic wallet.
///      Instead, the board is deployed THROUGH the canonical CREATE2
///      factory (Arachnid's deterministic deployment proxy,
///      0x4e59b44847b379578588920cA78FbF26c0B4956C), which IS a normal
///      contract call: calldata = salt (32 bytes) ++ init code.
///
///      This test etches the factory's real BSC-mainnet runtime bytecode
///      locally (verified via `cast code` on 19 Nov 2026) and proves the
///      full flow end-to-end, including the predicted address.
///
///      The board takes NO constructor arguments (the Agent ID registry is
///      hardcoded), so the init code is just the creation code.
contract Create2DeployTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant BSC_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    // Real runtime bytecode of the factory on BSC mainnet.
    bytes constant FACTORY_CODE = hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    // Production salt: keccak256("agent-quest-board-v1.1") — fixed so the
    // mainnet address is deterministic and reproducible.
    bytes32 constant SALT = keccak256("agent-quest-board-v1.1");

    function testDeployThroughFactory() public {
        vm.etch(FACTORY, FACTORY_CODE);
        MockAgentID mock = new MockAgentID();
        vm.etch(BSC_AGENT_ID, address(mock).code);
        MockAgentID agentId = MockAgentID(BSC_AGENT_ID);

        bytes memory initCode = type(AgentQuestBoard).creationCode;
        address predicted = vm.computeCreate2Address(SALT, keccak256(initCode), FACTORY);

        bytes memory factoryCalldata = abi.encodePacked(SALT, initCode);
        (bool ok, bytes memory ret) = FACTORY.call(factoryCalldata);
        assertTrue(ok, "factory deploy failed");

        // The factory returns the deployed address as raw 20 bytes.
        require(ret.length == 20, "unexpected factory return length");
        address deployed = address(bytes20(ret));
        assertEq(deployed, predicted, "deployed address mismatch");
        assertGt(deployed.code.length, 0, "no code at deployed address");

        // The board deployed through the factory must be fully functional.
        AgentQuestBoard board = AgentQuestBoard(payable(deployed));
        assertEq(address(board.AGENT_ID()), BSC_AGENT_ID);
        assertEq(board.questCount(), 0);
        assertEq(board.VERSION(), "1.1.0");

        address poster = address(0xA11CE);
        agentId.mint(poster);
        vm.deal(poster, 1 ether);
        vm.prank(poster);
        uint256 id = board.postQuest{value: 0.01 ether}("via factory", "works", 1 days);
        assertEq(board.getQuest(id).poster, poster);
    }

    function testDeployThroughFactory_SameSaltTwiceReverts() public {
        vm.etch(FACTORY, FACTORY_CODE);

        bytes memory initCode = type(AgentQuestBoard).creationCode;
        bytes memory factoryCalldata = abi.encodePacked(SALT, initCode);

        (bool ok,) = FACTORY.call(factoryCalldata);
        assertTrue(ok, "first factory deploy failed");

        // Re-deploying the same salt + init code must fail (address taken).
        (ok,) = FACTORY.call(factoryCalldata);
        assertFalse(ok, "second deploy with same salt must fail");
    }
}
