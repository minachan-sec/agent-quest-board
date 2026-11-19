// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AgentQuestBoard} from "../../src/AgentQuestBoard.sol";
import {MockAgentID} from "../mocks/MockAgentID.sol";

/// @notice Handler that drives the board with random actions from 4 actors.
///         All calls are wrapped in try/catch: a revert is a legal outcome
///         (wrong status, wrong caller, too early), never a test failure.
///         Ghost variables track the accounting identity independently of
///         the contract's own counters.
contract BoardHandler is Test {
    AgentQuestBoard public board;

    address public actorA = address(0xA11CE);
    address public actorB = address(0xB0B);
    address public actorC = address(0xC0FFEE);
    address public actorD = address(0xD00D);

    // Ghost accounting (independent of the contract's counters).
    uint256 public ghostPostedTotal;
    uint256 public ghostWithdrawnTotal;
    uint256 public ghostPostCount;
    // Write-once record of the first terminal status seen per quest
    // (0 = not terminal yet, else uint8(status) + 1).
    mapping(uint256 => uint8) public ghostTerminalStatus;

    constructor(AgentQuestBoard _board) {
        board = _board;
    }

    function _actor(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 4;
        if (pick == 0) return actorA;
        if (pick == 1) return actorB;
        if (pick == 2) return actorC;
        return actorD;
    }

    function _questId(uint256 seed) internal view returns (uint256) {
        uint256 count = board.questCount();
        if (count == 0) return 0;
        return seed % count;
    }

    /// @dev Record a quest's terminal status the first time it is seen
    ///      (write-once: later calls never overwrite, so the invariant can
    ///      detect any change).
    function _syncTerminal(uint256 questId) internal {
        if (questId >= board.questCount()) return;
        if (ghostTerminalStatus[questId] != 0) return;
        AgentQuestBoard.Status s = board.getQuest(questId).status;
        if (s == AgentQuestBoard.Status.Completed || s == AgentQuestBoard.Status.Cancelled) {
            ghostTerminalStatus[questId] = uint8(s) + 1;
        }
    }

    function postQuest(uint256 actorSeed, uint256 rewardSeed, uint256 durationSeed) external {
        address actor = _actor(actorSeed);
        uint256 reward = bound(rewardSeed, board.MIN_REWARD(), 1 ether);
        uint256 duration = bound(durationSeed, board.MIN_DURATION(), board.MAX_DURATION());
        vm.deal(actor, actor.balance + reward);
        vm.prank(actor);
        try board.postQuest{value: reward}("t", "d", duration) returns (uint256 id) {
            ghostPostedTotal += reward;
            ghostPostCount++;
            _syncTerminal(id);
        } catch {}
    }

    function claimQuest(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.claimQuest(id) {} catch {}
        _syncTerminal(id);
    }

    function releaseQuest(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.releaseQuest(id) {} catch {}
        _syncTerminal(id);
    }

    function submitProof(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.submitProof(id, "proof") {} catch {}
        _syncTerminal(id);
    }

    function confirmCompletion(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.confirmCompletion(id) {} catch {}
        _syncTerminal(id);
    }

    function rejectSubmission(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.rejectSubmission(id) {} catch {}
        _syncTerminal(id);
    }

    function rejectAndRefund(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.rejectAndRefund(id) {} catch {}
        _syncTerminal(id);
    }

    function cancelQuest(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.cancelQuest(id) {} catch {}
        _syncTerminal(id);
    }

    function cancelExpiredClaim(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.cancelExpiredClaim(id) {} catch {}
        _syncTerminal(id);
    }

    function claimExpiredOpenRefund(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.claimExpiredOpenRefund(id) {} catch {}
        _syncTerminal(id);
    }

    function claimRewardAfterTimeout(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.claimRewardAfterTimeout(id) {} catch {}
        _syncTerminal(id);
    }

    function cancelStaleSubmission(uint256 actorSeed, uint256 questSeed) external {
        uint256 id = _questId(questSeed);
        vm.prank(_actor(actorSeed));
        try board.cancelStaleSubmission(id) {} catch {}
        _syncTerminal(id);
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 pending = board.pendingWithdrawals(actor);
        vm.prank(actor);
        try board.withdraw() {
            ghostWithdrawnTotal += pending;
        } catch {}
    }

    function withdrawTo(uint256 actorSeed, uint256 recipientSeed) external {
        address actor = _actor(actorSeed);
        address recipient = _actor(recipientSeed);
        uint256 pending = board.pendingWithdrawals(actor);
        vm.prank(actor);
        try board.withdrawTo(payable(recipient)) {
            ghostWithdrawnTotal += pending;
        } catch {}
    }

    function warpTime(uint256 secondsSeed) external {
        uint256 jump = bound(secondsSeed, 0, 30 days);
        vm.warp(block.timestamp + jump);
    }
}

contract AgentQuestBoardInvariantTest is StdInvariant, Test {
    AgentQuestBoard public board;
    MockAgentID public agentId;
    BoardHandler public handler;

    address constant BSC_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function setUp() public {
        MockAgentID mock = new MockAgentID();
        vm.etch(BSC_AGENT_ID, address(mock).code);
        agentId = MockAgentID(BSC_AGENT_ID);

        board = new AgentQuestBoard();
        handler = new BoardHandler(board);

        agentId.mint(handler.actorA());
        agentId.mint(handler.actorB());
        agentId.mint(handler.actorC());
        agentId.mint(handler.actorD());

        vm.deal(handler.actorA(), 1000 ether);
        vm.deal(handler.actorB(), 1000 ether);
        vm.deal(handler.actorC(), 1000 ether);
        vm.deal(handler.actorD(), 1000 ether);

        targetContract(address(handler));
    }

    /// @notice Accounting identity: escrowed + pending == posted - withdrawn.
    ///         Money is never created or destroyed by any action sequence.
    function invariant_accountingIdentity() public view {
        assertEq(
            board.totalEscrowed() + board.totalPendingWithdrawals(),
            handler.ghostPostedTotal() - handler.ghostWithdrawnTotal()
        );
    }

    /// @notice The contract always holds at least what it owes (>= because
    ///         forced BNB via SELFDESTRUCT can add surplus).
    function invariant_solvency() public view {
        assertGe(
            address(board).balance,
            board.totalEscrowed() + board.totalPendingWithdrawals()
        );
    }

    /// @notice Quest count matches the number of successful posts.
    function invariant_questCount() public view {
        assertEq(board.questCount(), handler.ghostPostCount());
    }

    /// @notice The sum of all actors' withdrawable balances equals the
    ///         contract's totalPendingWithdrawals (no phantom credits).
    function invariant_pendingSum() public view {
        uint256 sum = board.pendingWithdrawals(handler.actorA())
            + board.pendingWithdrawals(handler.actorB())
            + board.pendingWithdrawals(handler.actorC())
            + board.pendingWithdrawals(handler.actorD());
        assertEq(sum, board.totalPendingWithdrawals());
    }

    /// @notice Terminal statuses (Completed/Cancelled) never change once set.
    function invariant_terminalStatusStable() public view {
        uint256 count = board.questCount();
        for (uint256 i = 0; i < count; i++) {
            uint8 recorded = handler.ghostTerminalStatus(i);
            if (recorded != 0) {
                assertEq(
                    recorded,
                    uint8(board.getQuest(i).status) + 1,
                    "terminal status changed"
                );
            }
        }
    }
}
