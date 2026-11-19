// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentQuestBoard} from "../src/AgentQuestBoard.sol";

/// @notice Fork test against BSC mainnet and the REAL Agent ID registry.
///
/// @dev Run with:
///      FOUNDRY_FORK_URL=https://bsc-dataseed.binance.org/ forge test --match-contract ForkTest
///      Without FOUNDRY_FORK_URL the test returns immediately (passes
///      vacuously) so the default offline suite stays hermetic.
contract ForkTest is Test {
    address constant BSC_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant DOMBLANG = 0xddAf5e7adE3147Ab91f3Af1d80B5f19cE3b929Eb;
    address constant SKYBULLZ = 0x1a08443849138439C46667b80F8F174dd40CCd13;

    function testFork_RealAgentIDGating() public {
        string memory rpc = vm.envOr("FOUNDRY_FORK_URL", string(""));
        if (bytes(rpc).length == 0) return; // no fork configured: skip
        vm.createSelectFork(rpc);

        AgentQuestBoard board = new AgentQuestBoard();
        assertEq(address(board.AGENT_ID()), BSC_AGENT_ID);

        // Both agent wallets hold an Agent ID on mainnet (verified on-chain
        // 19 Nov 2026); a random address does not.
        assertTrue(board.isAgentIDHolder(DOMBLANG));
        assertTrue(board.isAgentIDHolder(SKYBULLZ));
        assertFalse(board.isAgentIDHolder(address(0x1234)));

        // Full happy path on a real fork: domblang posts, skybullz works.
        vm.deal(DOMBLANG, 1 ether);
        vm.prank(DOMBLANG);
        uint256 id = board.postQuest{value: 0.01 ether}("fork quest", "works", 1 days);
        vm.prank(SKYBULLZ);
        board.claimQuest(id);
        vm.prank(SKYBULLZ);
        board.submitProof(id, "proof");
        vm.prank(DOMBLANG);
        board.confirmCompletion(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
        assertEq(board.pendingWithdrawals(SKYBULLZ), 0.01 ether);

        // Pull-payment: the worker withdraws separately.
        uint256 before = SKYBULLZ.balance;
        vm.prank(SKYBULLZ);
        board.withdraw();
        assertEq(SKYBULLZ.balance, before + 0.01 ether);
        assertEq(board.pendingWithdrawals(SKYBULLZ), 0);
    }
}
