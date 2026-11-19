// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentQuestBoard} from "../src/AgentQuestBoard.sol";
import {MockAgentID, ReentrantWorker, UnpayableWorker} from "./mocks/MockAgentID.sol";

contract AgentQuestBoardTest is Test {
    AgentQuestBoard public board;
    MockAgentID public agentId;

    address constant BSC_AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address public poster = address(0xA11CE);
    address public worker = address(0xB0B);
    address public worker2 = address(0xC0FFEE);
    address public nonHolder = address(0xDEAD);

    uint256 constant REWARD = 0.05 ether;
    uint256 constant DURATION = 2 days;

    event QuestCreated(
        uint256 indexed questId, address indexed poster, uint256 reward, uint256 duration
    );
    event QuestAccepted(uint256 indexed questId, address indexed worker, uint256 deadline);
    event WorkSubmitted(uint256 indexed questId, address indexed worker);
    event QuestCompleted(
        uint256 indexed questId,
        address indexed poster,
        address indexed worker,
        uint256 reward
    );
    event QuestCancelled(uint256 indexed questId, address indexed poster, uint256 refund);
    event PaymentTimeoutClaimed(
        uint256 indexed questId,
        address indexed poster,
        address indexed worker,
        uint256 reward
    );
    event PaymentWithdrawn(address indexed account, uint256 amount);

    function setUp() public {
        // The board hardcodes the canonical BSC registry address. Etch the
        // mock's runtime code there so unit tests exercise the real gating
        // path (balanceOf on 0x60B9…022F) against controllable state.
        MockAgentID mock = new MockAgentID();
        vm.etch(BSC_AGENT_ID, address(mock).code);
        agentId = MockAgentID(BSC_AGENT_ID);

        board = new AgentQuestBoard();

        agentId.mint(poster);
        agentId.mint(worker);
        agentId.mint(worker2);

        vm.deal(poster, 10 ether);
        vm.deal(worker, 10 ether);
        vm.deal(worker2, 10 ether);
        vm.deal(nonHolder, 10 ether);
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

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

    function _postClaimSubmit() internal returns (uint256) {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        board.submitProof(id, "https://example.com/proof");
        return id;
    }

    /// @dev Pull-payment helper: settle-then-withdraw, asserting the
    ///      beneficiary's balance only moves on `withdraw()`.
    function _assertWithdrawable(address beneficiary, uint256 amount) internal view {
        assertEq(board.pendingWithdrawals(beneficiary), amount);
    }

    // ------------------------------------------------------------------------
    // Constructor / views
    // ------------------------------------------------------------------------

    function testRegistry_HardcodedCanonical() public view {
        assertEq(address(board.AGENT_ID()), BSC_AGENT_ID);
        assertEq(board.VERSION(), "1.1.0");
    }

    function testIsAgentIDHolder() public view {
        assertTrue(board.isAgentIDHolder(poster));
        assertFalse(board.isAgentIDHolder(nonHolder));
    }

    function testDirectTransfer_Reverts() public {
        vm.prank(poster);
        (bool ok,) = address(board).call{value: 0.01 ether}("");
        assertFalse(ok, "direct BNB transfer must be rejected");
        assertEq(address(board).balance, 0);
    }

    // ------------------------------------------------------------------------
    // postQuest
    // ------------------------------------------------------------------------

    function testPostQuest_HappyPath() public {
        vm.expectEmit(true, true, false, true);
        emit QuestCreated(0, poster, REWARD, DURATION);

        vm.prank(poster);
        uint256 id = board.postQuest{value: REWARD}("Write a thread", "Draft it", DURATION);

        assertEq(id, 0);
        assertEq(board.questCount(), 1);
        assertEq(address(board).balance, REWARD);
        assertEq(board.totalEscrowed(), REWARD);
        assertEq(board.totalPendingWithdrawals(), 0);

        AgentQuestBoard.Quest memory q = board.getQuest(0);
        assertEq(q.poster, poster);
        assertEq(q.worker, address(0));
        assertEq(q.reward, REWARD);
        assertEq(q.duration, DURATION);
        assertEq(q.deadline, 0);
        assertEq(q.postedAt, block.timestamp);
        assertEq(uint256(q.status), uint256(AgentQuestBoard.Status.Open));
        assertEq(q.title, "Write a thread");
        assertEq(q.details, "Draft it");

        (uint256 posted, uint256 completed, uint256 earned) = board.reputation(poster);
        assertEq(posted, 1);
        assertEq(completed, 0);
        assertEq(earned, 0);
    }

    function testPostQuest_RevertsForNonHolder() public {
        vm.prank(nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotAgentIDHolder.selector, nonHolder)
        );
        board.postQuest{value: REWARD}("t", "d", DURATION);
    }

    function testPostQuest_RevertsRewardTooLow() public {
        uint256 minReward = board.MIN_REWARD();
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.RewardTooLow.selector, 0.0005 ether, minReward
            )
        );
        board.postQuest{value: 0.0005 ether}("t", "d", DURATION);
    }

    function testPostQuest_AcceptsExactlyMinimum() public {
        uint256 minReward = board.MIN_REWARD();
        vm.prank(poster);
        uint256 id = board.postQuest{value: minReward}("t", "d", DURATION);
        assertEq(board.getQuest(id).reward, minReward);
    }

    function testPostQuest_RevertsBadDuration() public {
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.InvalidDuration.selector, 30 minutes)
        );
        board.postQuest{value: REWARD}("t", "d", 30 minutes);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.InvalidDuration.selector, 31 days)
        );
        board.postQuest{value: REWARD}("t", "d", 31 days);
    }

    function testPostQuest_RevertsEmptyTitle() public {
        vm.prank(poster);
        vm.expectRevert(AgentQuestBoard.TitleEmpty.selector);
        board.postQuest{value: REWARD}("", "d", DURATION);
    }

    function testPostQuest_RevertsTooLongText() public {
        string memory longTitle = new string(121);
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.TextTooLong.selector, 121, 120)
        );
        board.postQuest{value: REWARD}(longTitle, "d", DURATION);

        string memory longDetails = new string(2001);
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.TextTooLong.selector, 2001, 2000)
        );
        board.postQuest{value: REWARD}("t", longDetails, DURATION);
    }

    function testFuzz_PostQuest(uint96 rewardWei, uint32 durationSecs) public {
        uint256 reward = bound(uint256(rewardWei), board.MIN_REWARD(), 100 ether);
        uint256 duration =
            bound(uint256(durationSecs), board.MIN_DURATION(), board.MAX_DURATION());
        vm.deal(poster, reward + 1 ether);
        vm.prank(poster);
        uint256 id = board.postQuest{value: reward}("fuzz", "fuzz details", duration);
        assertEq(board.getQuest(id).reward, reward);
        assertEq(board.getQuest(id).duration, duration);
    }

    // ------------------------------------------------------------------------
    // claimQuest / releaseQuest
    // ------------------------------------------------------------------------

    function testClaimQuest_HappyPath() public {
        uint256 id = _postQuest();
        uint256 expectedDeadline = block.timestamp + DURATION;

        vm.expectEmit(true, true, false, true);
        emit QuestAccepted(id, worker, expectedDeadline);

        vm.prank(worker);
        board.claimQuest(id);

        AgentQuestBoard.Quest memory q = board.getQuest(id);
        assertEq(q.worker, worker);
        assertEq(q.deadline, expectedDeadline);
        assertEq(uint256(q.status), uint256(AgentQuestBoard.Status.Claimed));
    }

    function testClaimQuest_RevertsForNonHolder() public {
        uint256 id = _postQuest();
        vm.prank(nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotAgentIDHolder.selector, nonHolder)
        );
        board.claimQuest(id);
    }

    function testClaimQuest_RevertsOwnQuest() public {
        uint256 id = _postQuest();
        vm.prank(poster);
        vm.expectRevert(AgentQuestBoard.CannotClaimOwnQuest.selector);
        board.claimQuest(id);
    }

    function testClaimQuest_RevertsAlreadyClaimed() public {
        uint256 id = _postAndClaim();
        vm.prank(worker2);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.InvalidStatus.selector,
                id,
                AgentQuestBoard.Status.Open,
                AgentQuestBoard.Status.Claimed
            )
        );
        board.claimQuest(id);
    }

    function testReleaseQuest_ThenReclaim() public {
        uint256 id = _postAndClaim();

        vm.prank(worker);
        board.releaseQuest(id);

        AgentQuestBoard.Quest memory q = board.getQuest(id);
        assertEq(q.worker, address(0));
        assertEq(q.deadline, 0);
        assertEq(uint256(q.status), uint256(AgentQuestBoard.Status.Open));

        // Someone else can now claim it.
        vm.prank(worker2);
        board.claimQuest(id);
        assertEq(board.getQuest(id).worker, worker2);
    }

    function testReleaseQuest_RevertsNonWorker() public {
        uint256 id = _postAndClaim();
        vm.prank(worker2);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotWorker.selector, worker2)
        );
        board.releaseQuest(id);
    }

    function testReleaseQuest_RevertsAfterSubmit() public {
        uint256 id = _postClaimSubmit();
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.InvalidStatus.selector,
                id,
                AgentQuestBoard.Status.Claimed,
                AgentQuestBoard.Status.Submitted
            )
        );
        board.releaseQuest(id);
    }

    // ------------------------------------------------------------------------
    // submitProof
    // ------------------------------------------------------------------------

    function testSubmitProof_HappyPath() public {
        uint256 id = _postAndClaim();

        vm.expectEmit(true, true, false, false);
        emit WorkSubmitted(id, worker);

        vm.prank(worker);
        board.submitProof(id, "https://example.com/proof");

        AgentQuestBoard.Quest memory q = board.getQuest(id);
        assertEq(uint256(q.status), uint256(AgentQuestBoard.Status.Submitted));
        assertEq(q.proof, "https://example.com/proof");
        assertEq(q.submittedAt, block.timestamp);
    }

    function testSubmitProof_RevertsAfterDeadline() public {
        uint256 id = _postAndClaim();
        uint256 deadline = board.getQuest(id).deadline;
        vm.warp(deadline + 1);

        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.DeadlinePassed.selector, id, deadline)
        );
        board.submitProof(id, "late");
    }

    function testSubmitProof_RevertsNonWorker() public {
        uint256 id = _postAndClaim();
        vm.prank(worker2);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotWorker.selector, worker2)
        );
        board.submitProof(id, "not mine");
    }

    function testSubmitProof_RevertsTooLongProof() public {
        uint256 id = _postAndClaim();
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.TextTooLong.selector, 1001, 1000)
        );
        board.submitProof(id, new string(1001));
    }

    // ------------------------------------------------------------------------
    // confirmCompletion / rejectSubmission (pull-payment + review window)
    // ------------------------------------------------------------------------

    function testConfirmCompletion_HappyPath() public {
        uint256 id = _postClaimSubmit();
        uint256 workerBefore = worker.balance;

        vm.expectEmit(true, true, true, true);
        emit QuestCompleted(id, poster, worker, REWARD);

        vm.prank(poster);
        board.confirmCompletion(id);

        // Pull-payment: confirm credits, it does NOT transfer.
        assertEq(worker.balance, workerBefore);
        _assertWithdrawable(worker, REWARD);
        assertEq(board.totalEscrowed(), 0);
        assertEq(board.totalPendingWithdrawals(), REWARD);
        assertEq(address(board).balance, REWARD);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));

        (,, uint256 earned) = board.reputation(worker);
        (, uint256 completed,) = board.reputation(worker);
        assertEq(completed, 1);
        assertEq(earned, REWARD);

        // The worker pulls the funds with a separate withdraw().
        vm.expectEmit(true, false, false, true);
        emit PaymentWithdrawn(worker, REWARD);
        vm.prank(worker);
        board.withdraw();
        assertEq(worker.balance, workerBefore + REWARD);
        assertEq(board.pendingWithdrawals(worker), 0);
        assertEq(address(board).balance, 0);
    }

    function testConfirmCompletion_RevertsNonPoster() public {
        uint256 id = _postClaimSubmit();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentQuestBoard.NotPoster.selector, worker));
        board.confirmCompletion(id);
    }

    function testConfirmCompletion_RevertsWrongStatus() public {
        uint256 id = _postAndClaim(); // Claimed, not Submitted
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.InvalidStatus.selector,
                id,
                AgentQuestBoard.Status.Submitted,
                AgentQuestBoard.Status.Claimed
            )
        );
        board.confirmCompletion(id);
    }

    function testRejectSubmission_ThenResubmit_ThenConfirm() public {
        uint256 id = _postClaimSubmit();

        vm.prank(poster);
        board.rejectSubmission(id);

        AgentQuestBoard.Quest memory q = board.getQuest(id);
        assertEq(uint256(q.status), uint256(AgentQuestBoard.Status.Claimed));
        assertEq(bytes(q.proof).length, 0);
        assertEq(q.submittedAt, 0);

        vm.prank(worker);
        board.submitProof(id, "better proof");
        vm.prank(poster);
        board.confirmCompletion(id);

        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
        (, uint256 completed,) = board.reputation(worker);
        assertEq(completed, 1);
    }

    function testRejectSubmission_AllowedAfterDeadlineWithinReview() public {
        // The review window is measured from SUBMISSION, not from the work
        // deadline: a submission made before the deadline can still be
        // rejected after the deadline passes, as long as the 7-day review
        // window has not ended.
        uint256 id = _postClaimSubmit();
        uint256 deadline = board.getQuest(id).deadline;
        uint256 reviewEnd = board.getQuest(id).submittedAt + board.REVIEW_WINDOW();
        vm.warp(deadline + 1);
        assertLt(block.timestamp, reviewEnd);

        vm.prank(poster);
        board.rejectSubmission(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Claimed));
        // The worker got a guaranteed 24h resubmit window.
        assertEq(board.getQuest(id).deadline, block.timestamp + board.RESUBMIT_WINDOW());

        vm.prank(worker);
        board.submitProof(id, "better proof");
        vm.prank(poster);
        board.confirmCompletion(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
    }

    function testRejectSubmission_RevertsAfterReviewWindow() public {
        uint256 id = _postClaimSubmit();
        uint256 reviewEnd = board.getQuest(id).submittedAt + board.REVIEW_WINDOW();
        vm.warp(reviewEnd);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.ReviewWindowPassed.selector, id, reviewEnd
            )
        );
        board.rejectSubmission(id);
    }

    // ------------------------------------------------------------------------
    // cancelQuest / cancelExpiredClaim
    // ------------------------------------------------------------------------

    function testCancelQuest_Open_Refunds() public {
        uint256 id = _postQuest();
        uint256 posterBefore = poster.balance;

        vm.expectEmit(true, true, false, true);
        emit QuestCancelled(id, poster, REWARD);

        vm.prank(poster);
        board.cancelQuest(id);

        // Pull-payment: cancel credits, withdraw moves the funds.
        assertEq(poster.balance, posterBefore);
        _assertWithdrawable(poster, REWARD);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));

        vm.prank(poster);
        board.withdraw();
        assertEq(poster.balance, posterBefore + REWARD);
        assertEq(address(board).balance, 0);
    }

    function testCancelQuest_RevertsAfterClaim() public {
        uint256 id = _postAndClaim();
        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.InvalidStatus.selector,
                id,
                AgentQuestBoard.Status.Open,
                AgentQuestBoard.Status.Claimed
            )
        );
        board.cancelQuest(id);
    }

    function testCancelQuest_RevertsNonPoster() public {
        uint256 id = _postQuest();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentQuestBoard.NotPoster.selector, worker));
        board.cancelQuest(id);
    }

    function testCancelExpiredClaim_AfterDeadline_Refunds() public {
        uint256 id = _postAndClaim();
        uint256 posterBefore = poster.balance;
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(poster);
        board.cancelExpiredClaim(id);

        assertEq(poster.balance, posterBefore);
        _assertWithdrawable(poster, REWARD);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Cancelled));

        vm.prank(poster);
        board.withdraw();
        assertEq(poster.balance, posterBefore + REWARD);
        assertEq(address(board).balance, 0);
    }

    function testCancelExpiredClaim_RevertsBeforeDeadline() public {
        uint256 id = _postAndClaim();
        uint256 deadline = board.getQuest(id).deadline;

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.DeadlineNotReached.selector, id, deadline
            )
        );
        board.cancelExpiredClaim(id);
    }

    function testCancelExpiredClaim_RevertsWhenSubmitted() public {
        // A timely submission protects the worker: the poster cannot grab
        // the refund just because the deadline passed afterwards.
        uint256 id = _postClaimSubmit();
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(poster);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.InvalidStatus.selector,
                id,
                AgentQuestBoard.Status.Claimed,
                AgentQuestBoard.Status.Submitted
            )
        );
        board.cancelExpiredClaim(id);
    }

    // ------------------------------------------------------------------------
    // claimRewardAfterTimeout / cancelStaleSubmission
    // ------------------------------------------------------------------------

    function testClaimRewardAfterTimeout_HappyPath() public {
        uint256 id = _postClaimSubmit();
        uint256 workerBefore = worker.balance;

        // Poster ignores the submission for the full review window.
        vm.warp(block.timestamp + board.REVIEW_WINDOW());

        vm.expectEmit(true, true, true, true);
        emit PaymentTimeoutClaimed(id, poster, worker, REWARD);

        vm.prank(worker);
        board.claimRewardAfterTimeout(id);

        assertEq(worker.balance, workerBefore);
        _assertWithdrawable(worker, REWARD);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
        (, uint256 completed, uint256 earned) = board.reputation(worker);
        assertEq(completed, 1);
        assertEq(earned, REWARD);

        vm.prank(worker);
        board.withdraw();
        assertEq(worker.balance, workerBefore + REWARD);
        assertEq(address(board).balance, 0);
    }

    function testClaimRewardAfterTimeout_RevertsTooEarly() public {
        uint256 id = _postClaimSubmit();
        uint256 reviewWindow = board.REVIEW_WINDOW();
        uint256 submittedAt = board.getQuest(id).submittedAt;
        vm.warp(submittedAt + reviewWindow - 1);

        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.ReviewWindowNotPassed.selector,
                id,
                submittedAt + reviewWindow
            )
        );
        board.claimRewardAfterTimeout(id);
    }

    function testClaimRewardAfterTimeout_RevertsNonWorker() public {
        uint256 id = _postClaimSubmit();
        vm.warp(block.timestamp + board.REVIEW_WINDOW() + 1);

        vm.prank(worker2);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotWorker.selector, worker2)
        );
        board.claimRewardAfterTimeout(id);
    }

    function testUnpayableWorker_PullPayment() public {
        // Worker is a contract that cannot receive BNB. Under pull-payment
        // the settlement still succeeds (it only credits a balance); only
        // the worker's OWN withdraw reverts, and nobody else is affected.
        UnpayableWorker unpayable = new UnpayableWorker();
        agentId.mint(address(unpayable));

        uint256 id = _postQuest();
        vm.prank(address(unpayable));
        board.claimQuest(id);
        vm.prank(address(unpayable));
        board.submitProof(id, "done");

        // Poster confirms: succeeds (credit, no transfer).
        vm.prank(poster);
        board.confirmCompletion(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
        _assertWithdrawable(address(unpayable), REWARD);
        assertEq(board.totalEscrowed(), 0);
        assertEq(board.totalPendingWithdrawals(), REWARD);

        // The unpayable worker's own withdraw reverts; its credit stays.
        vm.prank(address(unpayable));
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentQuestBoard.TransferFailed.selector, address(unpayable), REWARD
            )
        );
        board.withdraw();
        _assertWithdrawable(address(unpayable), REWARD);

        // Other parties are unaffected: a second quest settles + withdraws.
        uint256 id2 = _postQuest();
        vm.prank(poster);
        board.cancelQuest(id2);
        uint256 posterBefore = poster.balance;
        vm.prank(poster);
        board.withdraw();
        assertEq(poster.balance, posterBefore + REWARD);
    }

    // ------------------------------------------------------------------------
    // withdraw / reentrancy
    // ------------------------------------------------------------------------

    function testWithdraw_RevertsNothingToWithdraw() public {
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NothingToWithdraw.selector, worker)
        );
        board.withdraw();
    }

    function testReentrancy_Withdraw_PaysOnlyOnce() public {
        ReentrantWorker attacker = new ReentrantWorker(address(board));
        agentId.mint(address(attacker));
        vm.deal(address(attacker), 1 ether);

        uint256 id = _postQuest();
        vm.prank(address(attacker));
        board.claimQuest(id);
        vm.prank(address(attacker));
        board.submitProof(id, "evil proof");

        // Settlement only credits — no external call happens here, so
        // there is nothing to re-enter at confirm time.
        vm.prank(poster);
        board.confirmCompletion(id);
        assertEq(attacker.calls(), 0);
        _assertWithdrawable(address(attacker), REWARD);

        uint256 attackerBefore = address(attacker).balance;

        // The attacker's receive() tries to re-enter withdraw().
        // The guard blocks the inner call, so the outer withdraw pays
        // exactly ONCE.
        vm.prank(address(attacker));
        board.withdraw();

        assertEq(address(attacker).balance, attackerBefore + REWARD);
        assertEq(board.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(board).balance, 0);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));
        (, uint256 completed, uint256 earned) = board.reputation(address(attacker));
        assertEq(completed, 1);
        assertEq(earned, REWARD);
        assertEq(attacker.calls(), 1); // re-entry was attempted exactly once
    }

    function testReentrancy_WithdrawTo_PaysOnlyOnce() public {
        // withdrawTo shares the reentrancy guard with withdraw(): an
        // attacker whose receive() re-enters during a withdrawTo payout
        // must still be paid exactly once.
        ReentrantWorker attacker = new ReentrantWorker(address(board));
        agentId.mint(address(attacker));
        vm.deal(address(attacker), 1 ether);

        uint256 id = _postQuest();
        vm.prank(address(attacker));
        board.claimQuest(id);
        vm.prank(address(attacker));
        board.submitProof(id, "evil proof");
        vm.prank(poster);
        board.confirmCompletion(id);

        uint256 attackerBefore = address(attacker).balance;
        vm.prank(address(attacker));
        board.withdrawTo(payable(address(attacker)));

        assertEq(address(attacker).balance, attackerBefore + REWARD);
        assertEq(board.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(board).balance, 0);
        assertEq(attacker.calls(), 1); // re-entry was attempted exactly once
    }

    // ------------------------------------------------------------------------
    // Views / pagination / edge cases
    // ------------------------------------------------------------------------

    function testGetQuest_RevertsUnknownId() public {
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.QuestDoesNotExist.selector, 99)
        );
        board.getQuest(99);
    }

    function testGetQuests_Pagination() public {
        for (uint256 i = 0; i < 5; i++) {
            _postQuest();
        }
        (AgentQuestBoard.Quest[] memory page, uint256 total) = board.getQuests(1, 2);
        assertEq(total, 5);
        assertEq(page.length, 2);
        assertEq(page[0].poster, poster);

        (page, total) = board.getQuests(4, 10); // clamped to the end
        assertEq(page.length, 1);

        (page, total) = board.getQuests(5, 10); // past the end
        assertEq(page.length, 0);
        assertEq(total, 5);

        (page,) = board.getQuests(0, 0); // zero limit
        assertEq(page.length, 0);
    }

    function testEscrowAccounting_MultipleQuests() public {
        // Invariant: board balance == totalEscrowed + totalPendingWithdrawals
        // at every step (equality holds here because no forced BNB exists
        // in tests; the contract documents `>=` for the SELFDESTRUCT case).
        uint256 id1 = _postQuest();
        uint256 id2 = _postQuest();
        assertEq(address(board).balance, 2 * REWARD);
        assertEq(board.totalEscrowed(), 2 * REWARD);
        assertEq(board.totalPendingWithdrawals(), 0);

        vm.prank(poster);
        board.cancelQuest(id1);
        assertEq(address(board).balance, 2 * REWARD);
        assertEq(board.totalEscrowed(), REWARD);
        assertEq(board.totalPendingWithdrawals(), REWARD);

        vm.prank(worker);
        board.claimQuest(id2);
        vm.prank(worker);
        board.submitProof(id2, "p");
        vm.prank(poster);
        board.confirmCompletion(id2);
        assertEq(address(board).balance, 2 * REWARD);
        assertEq(board.totalEscrowed(), 0);
        assertEq(board.totalPendingWithdrawals(), 2 * REWARD);

        vm.prank(poster);
        board.withdraw();
        vm.prank(worker);
        board.withdraw();
        assertEq(address(board).balance, 0);
        assertEq(board.totalPendingWithdrawals(), 0);
    }

    function testHolderLosesId_MidFlow() public {
        // Edge case: a worker's Agent ID is burned after claiming (IDs are
        // non-transferable, but the registry could theoretically revoke).
        // Post/claim are gated, but in-flight actions are NOT re-gated, so
        // an in-flight quest is never bricked by a registry change.
        uint256 id = _postAndClaim();
        agentId.burn(worker);

        vm.prank(worker);
        board.submitProof(id, "still works");
        vm.prank(poster);
        board.confirmCompletion(id);
        assertEq(uint256(board.getQuest(id).status), uint256(AgentQuestBoard.Status.Completed));

        // But the ex-holder can no longer start new quests.
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(AgentQuestBoard.NotAgentIDHolder.selector, worker)
        );
        board.postQuest{value: REWARD}("t", "d", DURATION);
    }
}
