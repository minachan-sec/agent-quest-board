// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentQuestBoard} from "../src/AgentQuestBoard.sol";
import {MockAgentID, UnpayableWorker} from "./mocks/MockAgentID.sol";

/// @notice Tests for the v1.1.0 fixes: timeout cluster (M-2/M-3),
///         pull-payment edge cases (M-1), Open expiry + permissionless
///         refunds (L-1), reject-and-refund (L-2), release griefing (L-3),
///         day-14 cutoff (L-4), pagination cap (I-2).
contract FixesTest is Test {
    AgentQuestBoard public board;
    MockAgentID public agentId;

    address constant BSC_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address public poster = address(0xA11CE);
    address public worker = address(0xB0B);
    address public worker2 = address(0xC0FFEE);
    address public bystander = address(0xBEEF);

    uint256 constant REWARD = 0.05 ether;
    uint256 constant DURATION = 2 days;

    function setUp() public {
        MockAgentID mock = new MockAgentID();
        vm.etch(BSC_AGENT_ID, address(mock).code);
        agentId = MockAgentID(BSC_AGENT_ID);

        board = new AgentQuestBoard();

        agentId.mint(poster);
        agentId.mint(worker);
        agentId.mint(worker2);

        vm.deal(poster, 100 ether);
        vm.deal(worker, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(bystander, 10 ether);
    }

    function _postQuest() internal returns (uint256) {
        vm.prank(poster);
        return board.postQuest{value: REWARD}("Write a thread", "Draft a 5-post thread", DURATION);
    }

    function _postAndClaim() internal returns (uint256) {
        uint256 id = _postQuest();
        vm.prank(worker);
        board.claimQuest(id);
        return id;
    }

    // ------------------------------------------------------------------------
    // M-2: empty proof
    // ------------------------------------------------------------------------

    function testSubmitProof_RevertsEmptyProof() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        vm.expectRevert(AgentQuestBoard.ProofEmpty.selector);
        board.submitProof(id, "");
    }

    // ------------------------------------------------------------------------
    // M-3: last-second reject + guaranteed resubmit window
    // ------------------------------------------------------------------------

    function testReject_LastSecond_StillResubmittable() public {
        uint256 id = _postAndClaim();
        uint256 deadline = board.getQuest(id).deadline;

        // Worker submits 1 minute before the deadline.
        vm.warp(deadline - 1 minutes);
        vm.prank(worker);
        board.submitProof(id, "last-minute proof");

        // Poster rejects exactly at the deadline (the old griefing move).
        vm.warp(deadline);
        vm.prank(poster);
        board.rejectSubmission(id);

        // The worker MUST still be able to resubmit: the deadline was
        // extended to now + 24h.
        assertEq(board.getQuest(id).deadline, deadline + board.RESUBMIT_WINDOW());
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Claimed));

        vm.warp(deadline + 1 hours);
        vm.prank(worker);
        board.submitProof(id, "improved proof");
        vm.prank(poster);
        board.confirmCompletion(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
    }

    function testReject_ResubmitWindowExpires() public {
        uint256 id = _postAndClaim();
        uint256 deadline = board.getQuest(id).deadline;

        vm.warp(deadline - 1 minutes);
        vm.prank(worker);
        board.submitProof(id, "proof");
        vm.warp(deadline);
        vm.prank(poster);
        board.rejectSubmission(id);

        // After the guaranteed 24h resubmit window, submit reverts again.
        uint256 newDeadline = board.getQuest(id).deadline;
        vm.warp(newDeadline + 1);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.DeadlinePassed.selector, id, newDeadline)
        );
        board.submitProof(id, "too late");
    }

    // ------------------------------------------------------------------------
    // M-1: unpayable poster
    // ------------------------------------------------------------------------

    function testUnpayablePoster_CancelCredits_WithdrawReverts() public {
        UnpayableWorker unpayablePoster = new UnpayableWorker();
        agentId.mint(address(unpayablePoster));
        vm.deal(address(unpayablePoster), 1 ether);

        vm.prank(address(unpayablePoster));
        uint256 id = board.postQuest{value: REWARD}("t", "d", DURATION);

        // Cancel succeeds (credit, no transfer) even though the poster
        // cannot receive BNB.
        vm.prank(address(unpayablePoster));
        board.cancelQuest(id);
        assertEq(board.pendingWithdrawals(address(unpayablePoster)), REWARD);

        // Its own withdraw reverts; the credit stays (nobody else's funds
        // are affected).
        vm.prank(address(unpayablePoster));
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.TransferFailed.selector, address(unpayablePoster), REWARD
            )
        );
        board.withdraw();
        assertEq(board.pendingWithdrawals(address(unpayablePoster)), REWARD);
    }

    function testUnpayablePoster_WorkerStillPaid() public {
        // Even with an unpayable poster, the worker's completion + withdraw
        // path is fully independent.
        UnpayableWorker unpayablePoster = new UnpayableWorker();
        agentId.mint(address(unpayablePoster));
        vm.deal(address(unpayablePoster), 1 ether);

        vm.prank(address(unpayablePoster));
        uint256 id = board.postQuest{value: REWARD}("t", "d", DURATION);
        vm.prank(worker);
        board.claimQuest(id);
        vm.prank(worker);
        board.submitProof(id, "done");
        vm.prank(address(unpayablePoster));
        board.confirmCompletion(id);

        uint256 before = worker.balance;
        vm.prank(worker);
        board.withdraw();
        assertEq(worker.balance, before + REWARD);
    }

    // ------------------------------------------------------------------------
    // L-4: exclusive day-14 cutoff
    // ------------------------------------------------------------------------

    function testClaimWindow_Day13Succeeds_Day14Reverts() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "proof");
        uint256 submittedAt = board.getQuest(id).submittedAt;
        uint256 reviewEnd = submittedAt + board.REVIEW_WINDOW();
        uint256 cutoff = reviewEnd + board.STALE_GRACE_PERIOD();

        // Day 13 (one second before the cutoff): worker claim succeeds.
        uint256 id2 = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id2, "proof");
        vm.warp(cutoff - 1);
        vm.prank(worker);
        board.claimRewardAfterTimeout(id2);
        assertEq(uint256(board.getQuest(id2).status), uint256(AgentQuestBoard.Status.Completed));

        // Day 14 (exactly at the cutoff): worker claim reverts.
        vm.warp(cutoff);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.ClaimWindowExpired.selector, id, cutoff)
        );
        board.claimRewardAfterTimeout(id);

        // And the poster may now recover the escrow instead.
        vm.prank(poster);
        board.cancelStaleSubmission(id);
        assertEq(board.pendingWithdrawals(poster), REWARD);
    }

    function testCancelStaleSubmission_RevertsBeforeCutoff() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "proof");
        uint256 submittedAt = board.getQuest(id).submittedAt;
        uint256 cutoff = submittedAt + board.REVIEW_WINDOW() + board.STALE_GRACE_PERIOD();
        vm.warp(cutoff - 1);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.StaleGraceNotPassed.selector, id, cutoff
            )
        );
        board.cancelStaleSubmission(id);
    }

    function testCancelStaleSubmission_Permissionless() public {
        // Re-audit fix (GPT Medium #2): if the worker misses the day-14
        // window AND the poster disappears, a Submitted quest must still
        // settle. Anyone may trigger the stale refund to the poster.
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "proof");
        uint256 cutoff =
            board.getQuest(id).submittedAt + board.REVIEW_WINDOW() + board.STALE_GRACE_PERIOD();
        vm.warp(cutoff);

        vm.prank(bystander);
        board.cancelStaleSubmission(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));
        assertEq(board.pendingWithdrawals(poster), REWARD);
        assertEq(board.pendingWithdrawals(bystander), 0);
    }

    // ------------------------------------------------------------------------
    // withdrawTo (re-audit fix, GPT Low)
    // ------------------------------------------------------------------------

    function testWithdrawTo_HappyPath() public {
        uint256 id = _postClaimSubmit();
        vm.prank(poster);
        board.confirmCompletion(id);

        uint256 before = worker2.balance;
        vm.prank(worker);
        board.withdrawTo(payable(worker2));
        assertEq(worker2.balance, before + REWARD);
        assertEq(board.pendingWithdrawals(worker), 0);
        assertEq(board.totalPendingWithdrawals(), 0);
    }

    function testWithdrawTo_RevertsZeroRecipient() public {
        uint256 id = _postClaimSubmit();
        vm.prank(poster);
        board.confirmCompletion(id);

        vm.prank(worker);
        vm.expectRevert(AgentQuestBoard.ZeroAddress.selector);
        board.withdrawTo(payable(address(0)));
        // Credit intact after the failed call.
        assertEq(board.pendingWithdrawals(worker), REWARD);
    }

    function testWithdrawTo_RevertsNothingToWithdraw() public {
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NothingToWithdraw.selector, worker)
        );
        board.withdrawTo(payable(worker2));
    }

    function testUnpayableWorker_RecoversViaWithdrawTo() public {
        // The GPT Low fix: a beneficiary that cannot receive BNB can
        // redirect its credit to an address it controls.
        UnpayableWorker unpayable = new UnpayableWorker();
        agentId.mint(address(unpayable));

        uint256 id = _postQuest();
        vm.prank(address(unpayable));
        board.claimQuest(id);
        vm.prank(address(unpayable));
        board.submitProof(id, "done");
        vm.prank(poster);
        board.confirmCompletion(id);

        // Plain withdraw reverts (it cannot receive BNB).
        vm.prank(address(unpayable));
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.TransferFailed.selector, address(unpayable), REWARD
            )
        );
        board.withdraw();

        // But redirecting the credit to an EOA it controls succeeds.
        uint256 before = worker2.balance;
        vm.prank(address(unpayable));
        board.withdrawTo(payable(worker2));
        assertEq(worker2.balance, before + REWARD);
        assertEq(board.pendingWithdrawals(address(unpayable)), 0);
    }

    function _postClaimSubmit() internal returns (uint256) {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "https://example.com/proof");
        return id;
    }

    // ------------------------------------------------------------------------
    // L-2: reject-and-refund
    // ------------------------------------------------------------------------

    function testRejectAndRefund_HappyPath() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "garbage");

        vm.prank(poster);
        board.rejectAndRefund(id);

        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));
        assertEq(board.pendingWithdrawals(poster), REWARD);
        assertEq(board.totalEscrowed(), 0);
    }

    function testRejectAndRefund_RevertsAfterReviewWindow() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "proof");
        uint256 reviewEnd = board.getQuest(id).submittedAt + board.REVIEW_WINDOW();
        vm.warp(reviewEnd);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.ReviewWindowPassed.selector, id, reviewEnd
            )
        );
        board.rejectAndRefund(id);
    }

    // ------------------------------------------------------------------------
    // L-1: Open expiry + permissionless refunds
    // ------------------------------------------------------------------------

    function testOpenQuest_Expires_AnyoneCanRefund() public {
        uint256 id = _postQuest();
        uint256 expiry = board.getQuest(id).postedAt + board.OPEN_QUEST_LIFETIME();

        // Too early: refund reverts.
        vm.prank(bystander);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.OpenQuestNotExpired.selector, id, expiry
            )
        );
        board.claimExpiredOpenRefund(id);

        // After 90 days: ANYONE (even a non-holder bystander) can trigger
        // the refund, credited to the poster only.
        vm.warp(expiry);
        vm.prank(bystander);
        board.claimExpiredOpenRefund(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));
        assertEq(board.pendingWithdrawals(poster), REWARD);
        assertEq(board.pendingWithdrawals(bystander), 0);
    }

    function testClaimQuest_RevertsOnExpiredOpen() public {
        uint256 id = _postQuest();
        uint256 expiry = board.getQuest(id).postedAt + board.OPEN_QUEST_LIFETIME();
        vm.warp(expiry);

        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.OpenQuestExpired.selector, id, expiry)
        );
        board.claimQuest(id);
    }

    function testCancelExpiredClaim_Permissionless() public {
        uint256 id = _postAndClaim();
        vm.warp(block.timestamp + DURATION + 1);

        // A bystander (not the poster, not even a holder) triggers it.
        vm.prank(bystander);
        board.cancelExpiredClaim(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));
        assertEq(board.pendingWithdrawals(poster), REWARD);
        assertEq(board.pendingWithdrawals(bystander), 0);
    }

    // ------------------------------------------------------------------------
    // L-3: release after deadline blocked (griefing closed)
    // ------------------------------------------------------------------------

    function testReleaseQuest_RevertsAfterDeadline() public {
        uint256 id = _postAndClaim();
        uint256 deadline = board.getQuest(id).deadline;
        vm.warp(deadline + 1);

        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.DeadlinePassed.selector, id, deadline)
        );
        board.releaseQuest(id);

        // The poster can now recover via the expiry refund (permissionless).
        vm.prank(poster);
        board.cancelExpiredClaim(id);
        assertEq(board.pendingWithdrawals(poster), REWARD);
    }

    // ------------------------------------------------------------------------
    // I-2: pagination cap
    // ------------------------------------------------------------------------

    function testGetQuests_MaxPageSize() public {
        for (uint256 i = 0; i < 105; i++) {
            vm.prank(poster);
            board.postQuest{value: REWARD}("q", "d", DURATION);
        }
        (AgentQuestBoard.Quest[] memory page, uint256 total) = board.getQuests(0, 1000);
        assertEq(total, 105);
        assertEq(page.length, 100); // clamped to MAX_PAGE_SIZE

        (page,) = board.getQuests(100, 1000);
        assertEq(page.length, 5); // remaining clamp
    }
}
