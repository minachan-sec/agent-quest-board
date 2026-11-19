// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal interface of the SPACE ID Agent ID ERC-721 on BNB Smart Chain.
/// @dev Only `balanceOf` is needed: holding at least one Agent ID (.ai) proves
///      the caller is an Agent ID holder. The canonical mainnet address is
///      0x60b9262456de011f7d15a54cdd8c48baaa8b022f.
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title AgentQuestBoard
/// @author minachan-sec
/// @notice A micro-task escrow board for Binance Agent ID (.ai) holders.
///
/// @dev How it works:
///  1. A holder posts a quest and locks BNB as escrow (`postQuest`).
///  2. Another holder claims it (`claimQuest`) and gets a fixed time window
///     to finish the work.
///  3. The worker submits proof (`submitProof`); the poster confirms
///     (`confirmCompletion`) and the escrow is credited to the worker's
///     withdrawable balance (pull-payment; see below).
///  4. Safety valves:
///     - the worker can release an unstarted claim (`releaseQuest`);
///     - the poster can cancel an unclaimed quest (`cancelQuest`);
///     - if the worker never delivers, anyone may trigger a refund of the
///       escrow to the poster after the deadline (`cancelExpiredClaim`,
///       permissionless);
///     - an Open quest that is never claimed expires after 90 days and
///       anyone may trigger its refund (`claimExpiredOpenRefund`,
///       permissionless);
///     - if the poster ignores a timely submission, the worker can claim
///       the reward after a 7-day review window (`claimRewardAfterTimeout`);
///     - if a submission is never claimed by the worker, anyone can
///       trigger recovery of the escrow to the poster 14 days after
///       submission (`cancelStaleSubmission`, permissionless — so a
///       Submitted quest is never left unsettled if both parties
///       disappear).
///
/// @dev Time model (single-timestamp review window — no overlaps, no races):
///  - Work deadline: `deadline = claimedAt + duration`. Proof must be
///    submitted at or before it.
///  - Review end: `reviewEnd = submittedAt + REVIEW_WINDOW` (7 days).
///    The poster may reject only while `now < reviewEnd`. The worker may
///    claim unilaterally only while `reviewEnd <= now < staleCutoff`.
///  - Stale cutoff: `staleCutoff = submittedAt + REVIEW_WINDOW +
///    STALE_GRACE_PERIOD` (14 days). At/after it, only the poster may
///    recover the escrow. The boundary belongs to exactly one party at
///    every instant, so a reject and a claim can never race each other.
///  - Reject guarantees a resubmit window: on reject, the work deadline is
///    extended to `max(deadline, now + RESUBMIT_WINDOW)` (24h), so a
///    last-second reject can never strand the worker.
///
/// @dev Payments are PULL-based: every settlement only credits
///      `pendingWithdrawals[beneficiary]`; funds are withdrawn through
///      `withdraw()` (to the caller) or `withdrawTo(recipient)` (to an
///      address of the caller's choice — so a beneficiary that cannot
///      receive BNB itself can still recover its credit). A beneficiary
///      that cannot receive BNB can never block anyone else's settlement
///      — its own credit simply stays withdrawable.
///      Accounting invariant (note the `>=`, not `==`: forced BNB via
///      SELFDESTRUCT can add surplus that is not part of the accounting):
///      `address(this).balance >= totalEscrowed + totalPendingWithdrawals`.
///
/// @dev Trust model — deliberately ownerless:
///  - There is NO owner and NO admin key. All parameters are immutable
///    constants. Nobody — not even the deployer — can move escrowed funds,
///    change the rules, pause the board, or upgrade the contract.
///  - The Agent ID registry address is HARDCODED to the canonical BSC
///    mainnet registry (0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F,
///    verified against the Binance announcement and SPACE ID docs), so a
///    deploy-time registry mistake is impossible by construction.
///  - Funds can only ever flow poster -> worker (on completion) or back to
///    the poster (on cancel/timeout), exactly as the state machine above
///    describes.
///  - Reputation (quests posted, quests completed, BNB earned) is recorded
///    per wallet address. Because Agent IDs are non-transferable, a
///    holder's work history is bound to their .ai name and cannot be
///    reset by moving to a new wallet. Reputation proves "tasks completed
///    and paid", NOT "the work was good" — see the README for the honest
///    limits (self-dealing via a second wallet cannot be prevented
///    on-chain).
contract AgentQuestBoard is ReentrancyGuard {
    /// @notice The canonical Agent ID registry on BSC mainnet, hardcoded so
    ///         a deploy-time registry mistake is impossible. Verified against
    ///         the Binance hackathon announcement and SPACE ID docs
    ///         (https://docs.space.id/agent-id.md).
    IAgentID public constant AGENT_ID =
        IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);

    /// @notice Contract version, for off-chain tooling and verification.
    string public constant VERSION = "1.1.0";

    /// @notice Minimum escrow per quest (anti-spam / dust floor).
    uint256 public constant MIN_REWARD = 0.001 ether;
    /// @notice Shortest completion window a poster may set.
    uint256 public constant MIN_DURATION = 1 hours;
    /// @notice Longest completion window a poster may set.
    uint256 public constant MAX_DURATION = 30 days;
    /// @notice How long a poster has to review a submission before the
    ///         worker may claim the reward unilaterally.
    uint256 public constant REVIEW_WINDOW = 7 days;
    /// @notice Extra grace period after the review window before a poster
    ///         may recover escrow from a submission the worker never claimed.
    uint256 public constant STALE_GRACE_PERIOD = 7 days;
    /// @notice How long an Open quest lives before anyone may trigger its
    ///         refund to the poster.
    uint256 public constant OPEN_QUEST_LIFETIME = 90 days;
    /// @notice Guaranteed resubmit window granted to the worker after a
    ///         reject: the work deadline is extended to at least
    ///         `now + RESUBMIT_WINDOW` on every reject.
    uint256 public constant RESUBMIT_WINDOW = 24 hours;
    /// @notice Maximum page size for `getQuests`.
    uint256 public constant MAX_PAGE_SIZE = 100;
    /// @notice Maximum byte length of a quest title.
    uint256 public constant MAX_TITLE_LENGTH = 120;
    /// @notice Maximum byte length of a quest description.
    uint256 public constant MAX_DETAILS_LENGTH = 2000;
    /// @notice Maximum byte length of a proof of completion.
    uint256 public constant MAX_PROOF_LENGTH = 1000;

    enum Status {
        Open, // posted, waiting for a worker
        Claimed, // a worker took it, work in progress
        Submitted, // worker submitted proof, awaiting poster review
        Completed, // escrow credited to the worker (terminal)
        Cancelled // escrow credited back to the poster (terminal)

    }

    struct Quest {
        address poster;
        address worker;
        uint256 reward; // BNB locked in escrow
        uint256 duration; // seconds the worker has after claiming
        uint256 deadline; // claimedAt + duration (0 while Open)
        uint256 claimedAt; // 0 while Open
        uint256 submittedAt; // 0 until proof is submitted
        uint256 postedAt; // set at posting; Open quests expire 90 days after
        Status status;
        string title;
        string details;
        string proof; // worker's proof of completion (link or text)
    }

    /// @notice Total number of quests ever posted (also the next quest id).
    uint256 public questCount;

    /// @notice Sum of rewards of all non-terminal quests (on-chain escrow
    ///         liability). Decreases on every settlement (credit to a party).
    uint256 public totalEscrowed;

    /// @notice Sum of all withdrawable balances. Increases on every
    ///         settlement, decreases on every `withdraw`.
    uint256 public totalPendingWithdrawals;

    mapping(uint256 => Quest) public quests;
    /// @notice Pull-payment balances: BNB credited by settlements, waiting
    ///         for the beneficiary to call `withdraw()`.
    mapping(address => uint256) public pendingWithdrawals;
    /// @notice Reputation: quests posted per address.
    mapping(address => uint256) public postedCount;
    /// @notice Reputation: quests completed per address.
    mapping(address => uint256) public completedCount;
    /// @notice Reputation: total BNB earned as a worker per address.
    mapping(address => uint256) public totalEarned;

    event QuestCreated(
        uint256 indexed questId, address indexed poster, uint256 reward, uint256 duration
    );
    event QuestAccepted(uint256 indexed questId, address indexed worker, uint256 deadline);
    event QuestReleased(uint256 indexed questId, address indexed worker);
    event WorkSubmitted(uint256 indexed questId, address indexed worker);
    event WorkRejected(uint256 indexed questId, address indexed poster);
    event QuestCompleted(
        uint256 indexed questId,
        address indexed poster,
        address indexed worker,
        uint256 reward
    );
    event PaymentReleased(
        uint256 indexed questId, address indexed worker, uint256 reward
    );
    event PaymentWithdrawn(address indexed account, uint256 amount);
    event QuestCancelled(uint256 indexed questId, address indexed poster, uint256 refund);
    event QuestExpired(uint256 indexed questId, address indexed poster, uint256 refund);
    event RefundIssued(
        uint256 indexed questId, address indexed poster, uint256 refund
    );
    event PaymentTimeoutClaimed(
        uint256 indexed questId,
        address indexed poster,
        address indexed worker,
        uint256 reward
    );

    error NotAgentIDHolder(address account);
    error QuestDoesNotExist(uint256 questId);
    error InvalidStatus(uint256 questId, Status expected, Status actual);
    error NotPoster(address caller);
    error NotWorker(address caller);
    error CannotClaimOwnQuest();
    error RewardTooLow(uint256 provided, uint256 minimum);
    error InvalidDuration(uint256 duration);
    error TitleEmpty();
    error ProofEmpty();
    error TextTooLong(uint256 length, uint256 maxLength);
    error DeadlinePassed(uint256 questId, uint256 deadline);
    error DeadlineNotReached(uint256 questId, uint256 deadline);
    error ReviewWindowNotPassed(uint256 questId, uint256 earliestClaim);
    error ReviewWindowPassed(uint256 questId, uint256 reviewEnd);
    error ClaimWindowExpired(uint256 questId, uint256 cutoff);
    error StaleGraceNotPassed(uint256 questId, uint256 earliestCancel);
    error OpenQuestExpired(uint256 questId, uint256 expiry);
    error OpenQuestNotExpired(uint256 questId, uint256 expiry);
    error TransferFailed(address to, uint256 amount);
    error NothingToWithdraw(address account);
    error ZeroAddress();

    /// @notice Admission check: posting and claiming require holding an
    ///         Agent ID. In-flight actions (submit, confirm, reject, refund,
    ///         claim, withdraw) are intentionally NOT re-gated, so a quest
    ///         already in progress is never bricked by a registry change.
    modifier onlyAgentIDHolder() {
        if (AGENT_ID.balanceOf(msg.sender) == 0) revert NotAgentIDHolder(msg.sender);
        _;
    }

    /// @notice Post a quest and lock `msg.value` BNB as escrow.
    /// @param title Short title (1-120 bytes).
    /// @param details Full description, requirements, links (max 2000 bytes).
    /// @param duration Seconds the worker gets after claiming (1h - 30d).
    /// @return questId The id of the newly created quest.
    function postQuest(string calldata title, string calldata details, uint256 duration)
        external
        payable
        onlyAgentIDHolder
        returns (uint256 questId)
    {
        if (bytes(title).length == 0) revert TitleEmpty();
        if (bytes(title).length > MAX_TITLE_LENGTH) {
            revert TextTooLong(bytes(title).length, MAX_TITLE_LENGTH);
        }
        if (bytes(details).length > MAX_DETAILS_LENGTH) {
            revert TextTooLong(bytes(details).length, MAX_DETAILS_LENGTH);
        }
        if (msg.value < MIN_REWARD) revert RewardTooLow(msg.value, MIN_REWARD);
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert InvalidDuration(duration);
        }

        questId = questCount++;
        quests[questId] = Quest({
            poster: msg.sender,
            worker: address(0),
            reward: msg.value,
            duration: duration,
            deadline: 0,
            claimedAt: 0,
            submittedAt: 0,
            postedAt: block.timestamp,
            status: Status.Open,
            title: title,
            details: details,
            proof: ""
        });
        postedCount[msg.sender]++;
        totalEscrowed += msg.value;

        emit QuestCreated(questId, msg.sender, msg.value, duration);
    }

    /// @notice Claim an open quest. Starts the completion clock.
    /// @dev Reverts on an Open quest that already expired (90 days);
    ///      expired Open quests can only be refunded (see
    ///      `claimExpiredOpenRefund`).
    function claimQuest(uint256 questId) external onlyAgentIDHolder {
        Quest storage q = _quest(questId);
        if (q.status != Status.Open) revert InvalidStatus(questId, Status.Open, q.status);
        if (q.poster == msg.sender) revert CannotClaimOwnQuest();
        uint256 expiry = q.postedAt + OPEN_QUEST_LIFETIME;
        if (block.timestamp >= expiry) revert OpenQuestExpired(questId, expiry);

        q.worker = msg.sender;
        q.claimedAt = block.timestamp;
        q.deadline = block.timestamp + q.duration;
        q.status = Status.Claimed;

        emit QuestAccepted(questId, msg.sender, q.deadline);
    }

    /// @notice Give up a claim. The quest returns to Open and anyone else
    ///         may claim it. Only callable while no proof is pending and
    ///         at or before the deadline — after the deadline, the only way
    ///         out is the poster's expiry refund, so a worker cannot grief
    ///         the poster with release/re-claim cycles that refresh the
    ///         deadline. (A live claim can still be released and reclaimed
    ///         to restart the clock; the poster's remedy is to cancel while
    ///         the quest is Open, and the absolute bound is the 90-day Open
    ///         expiry anchored at `postedAt`.)
    function releaseQuest(uint256 questId) external {
        Quest storage q = _quest(questId);
        if (q.status != Status.Claimed) revert InvalidStatus(questId, Status.Claimed, q.status);
        if (q.worker != msg.sender) revert NotWorker(msg.sender);
        if (block.timestamp > q.deadline) revert DeadlinePassed(questId, q.deadline);

        address worker = q.worker;
        q.worker = address(0);
        q.claimedAt = 0;
        q.deadline = 0;
        q.status = Status.Open;

        emit QuestReleased(questId, worker);
    }

    /// @notice Submit proof of completion. Must be at or before the
    ///         deadline, and the proof must be non-empty (max 1000 bytes).
    /// @param proof Link or text describing the finished work.
    function submitProof(uint256 questId, string calldata proof) external {
        Quest storage q = _quest(questId);
        if (q.status != Status.Claimed) revert InvalidStatus(questId, Status.Claimed, q.status);
        if (q.worker != msg.sender) revert NotWorker(msg.sender);
        if (block.timestamp > q.deadline) revert DeadlinePassed(questId, q.deadline);
        if (bytes(proof).length == 0) revert ProofEmpty();
        if (bytes(proof).length > MAX_PROOF_LENGTH) {
            revert TextTooLong(bytes(proof).length, MAX_PROOF_LENGTH);
        }

        q.proof = proof;
        q.submittedAt = block.timestamp;
        q.status = Status.Submitted;

        emit WorkSubmitted(questId, msg.sender);
    }

    /// @notice Accept the proof and credit the escrow to the worker's
    ///         withdrawable balance (pull-payment). The worker withdraws
    ///         with `withdraw()` or `withdrawTo()`. Callable by the poster
    ///         at any time while the quest is Submitted — even after the
    ///         stale cutoff, since paying the worker for completed work is
    ///         always the poster's prerogative (but after day 14 anyone may
    ///         finalize the stale submission instead — see
    ///         `cancelStaleSubmission` — so a poster who wants to pay the
    ///         worker should confirm before day 14).
    function confirmCompletion(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Submitted) {
            revert InvalidStatus(questId, Status.Submitted, q.status);
        }
        if (q.poster != msg.sender) revert NotPoster(msg.sender);

        address worker = q.worker;
        uint256 reward = q.reward;
        q.status = Status.Completed;
        completedCount[worker]++;
        totalEarned[worker] += reward;
        _credit(worker, reward);

        emit QuestCompleted(questId, q.poster, worker, reward);
        emit PaymentReleased(questId, worker, reward);
    }

    /// @notice Reject the proof and send the quest back to Claimed so the
    ///         worker can improve and resubmit. Allowed only during the
    ///         review window (`now < submittedAt + REVIEW_WINDOW`) — the
    ///         window is measured from submission, NOT from the work
    ///         deadline, so a worker submitting one minute before the
    ///         deadline still gives the poster a full 7-day review.
    ///         On reject, the work deadline is extended to at least
    ///         `now + RESUBMIT_WINDOW` (24h), guaranteeing the worker a
    ///         real chance to resubmit — a last-second reject can never
    ///         strand the worker.
    function rejectSubmission(uint256 questId) external {
        Quest storage q = _quest(questId);
        if (q.status != Status.Submitted) {
            revert InvalidStatus(questId, Status.Submitted, q.status);
        }
        if (q.poster != msg.sender) revert NotPoster(msg.sender);
        uint256 reviewEnd = q.submittedAt + REVIEW_WINDOW;
        if (block.timestamp >= reviewEnd) revert ReviewWindowPassed(questId, reviewEnd);

        q.status = Status.Claimed;
        q.proof = "";
        q.submittedAt = 0;
        uint256 minDeadline = block.timestamp + RESUBMIT_WINDOW;
        if (q.deadline < minDeadline) q.deadline = minDeadline;

        emit WorkRejected(questId, msg.sender);
    }

    /// @notice Reject the proof AND refund the escrow to the poster
    ///         immediately (instead of returning the quest to Claimed).
    ///         Allowed only during the review window. Use this when the
    ///         submission is not worth another attempt and the poster does
    ///         not want its funds locked until the work deadline.
    function rejectAndRefund(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Submitted) {
            revert InvalidStatus(questId, Status.Submitted, q.status);
        }
        if (q.poster != msg.sender) revert NotPoster(msg.sender);
        uint256 reviewEnd = q.submittedAt + REVIEW_WINDOW;
        if (block.timestamp >= reviewEnd) revert ReviewWindowPassed(questId, reviewEnd);

        uint256 reward = q.reward;
        address poster = q.poster;
        q.status = Status.Cancelled;
        _credit(poster, reward);

        emit WorkRejected(questId, msg.sender);
        emit QuestCancelled(questId, poster, reward);
        emit RefundIssued(questId, poster, reward);
    }

    /// @notice Cancel an unclaimed quest and credit the escrow back to the
    ///         poster (withdrawable via `withdraw()`).
    function cancelQuest(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Open) revert InvalidStatus(questId, Status.Open, q.status);
        if (q.poster != msg.sender) revert NotPoster(msg.sender);

        uint256 reward = q.reward;
        address poster = q.poster;
        q.status = Status.Cancelled;
        _credit(poster, reward);

        emit QuestCancelled(questId, poster, reward);
        emit RefundIssued(questId, poster, reward);
    }

    /// @notice Recover escrow from a claim whose worker never delivered.
    ///         Only after the completion deadline has passed. PERMISSIONLESS:
    ///         anyone may trigger it; the refund is credited to the poster
    ///         only, so the caller gains nothing — a missing poster can
    ///         never leave escrow locked forever.
    function cancelExpiredClaim(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Claimed) revert InvalidStatus(questId, Status.Claimed, q.status);
        if (block.timestamp <= q.deadline) revert DeadlineNotReached(questId, q.deadline);

        uint256 reward = q.reward;
        address poster = q.poster;
        q.status = Status.Cancelled;
        _credit(poster, reward);

        emit QuestExpired(questId, poster, reward);
        emit RefundIssued(questId, poster, reward);
    }

    /// @notice Refund an Open quest that was never claimed within
    ///         OPEN_QUEST_LIFETIME (90 days). PERMISSIONLESS: anyone may
    ///         trigger it; the refund is credited to the poster only.
    function claimExpiredOpenRefund(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Open) revert InvalidStatus(questId, Status.Open, q.status);
        uint256 expiry = q.postedAt + OPEN_QUEST_LIFETIME;
        if (block.timestamp < expiry) revert OpenQuestNotExpired(questId, expiry);

        uint256 reward = q.reward;
        address poster = q.poster;
        q.status = Status.Cancelled;
        _credit(poster, reward);

        emit QuestExpired(questId, poster, reward);
        emit RefundIssued(questId, poster, reward);
    }

    /// @notice Worker-side protection: if the poster ignores a timely
    ///         submission for the full review window (7 days), the worker
    ///         may claim the reward without the poster's confirmation.
    ///         The claim window is EXCLUSIVE: it opens at
    ///         `submittedAt + REVIEW_WINDOW` and closes at
    ///         `submittedAt + REVIEW_WINDOW + STALE_GRACE_PERIOD` (day 14).
    ///         A worker that has not claimed by day 14 loses the unilateral
    ///         claim — after that, the escrow can only go back to the
    ///         poster (anyone may trigger the stale refund — see
    ///         `cancelStaleSubmission`). UIs MUST communicate this
    ///         hard 14-day deadline to workers.
    function claimRewardAfterTimeout(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Submitted) {
            revert InvalidStatus(questId, Status.Submitted, q.status);
        }
        if (q.worker != msg.sender) revert NotWorker(msg.sender);
        uint256 reviewEnd = q.submittedAt + REVIEW_WINDOW;
        if (block.timestamp < reviewEnd) revert ReviewWindowNotPassed(questId, reviewEnd);
        uint256 cutoff = reviewEnd + STALE_GRACE_PERIOD;
        if (block.timestamp >= cutoff) revert ClaimWindowExpired(questId, cutoff);

        address worker = q.worker;
        uint256 reward = q.reward;
        q.status = Status.Completed;
        completedCount[worker]++;
        totalEarned[worker] += reward;
        _credit(worker, reward);

        emit PaymentTimeoutClaimed(questId, q.poster, worker, reward);
        emit QuestCompleted(questId, q.poster, worker, reward);
        emit PaymentReleased(questId, worker, reward);
    }

    /// @notice Escape hatch for abandoned submissions: if the worker never
    ///         claims a submission (lost access, gave up, or missed the
    ///         day-14 window) the escrow can be recovered once the review
    ///         window plus a 7-day grace period have passed since submission
    ///         (day 14). PERMISSIONLESS: anyone may trigger it; the refund
    ///         is credited to the poster only, so the caller gains nothing
    ///         — a missing poster can never leave a Submitted quest
    ///         unsettled forever. Note this finalizes the quest: after a
    ///         third party triggers it, the poster can no longer
    ///         `confirmCompletion` to pay the worker instead, so a poster
    ///         who wants to pay should confirm before day 14.
    function cancelStaleSubmission(uint256 questId) external nonReentrant {
        Quest storage q = _quest(questId);
        if (q.status != Status.Submitted) {
            revert InvalidStatus(questId, Status.Submitted, q.status);
        }
        uint256 earliest = q.submittedAt + REVIEW_WINDOW + STALE_GRACE_PERIOD;
        if (block.timestamp < earliest) revert StaleGraceNotPassed(questId, earliest);

        uint256 reward = q.reward;
        address poster = q.poster;
        q.status = Status.Cancelled;
        _credit(poster, reward);

        emit QuestCancelled(questId, poster, reward);
        emit RefundIssued(questId, poster, reward);
    }

    /// @notice Withdraw BNB credited to the caller by settlements
    ///         (pull-payment). Checks-effects-interactions: the balance is
    ///         zeroed BEFORE the external call, and the call is guarded by
    ///         `nonReentrant`. A caller that cannot receive BNB simply
    ///         keeps its credit (the call reverts, the credit stays) — it
    ///         can never block anyone else. See `withdrawTo` for a
    ///         beneficiary that cannot receive BNB at all.
    function withdraw() external nonReentrant {
        _withdrawTo(payable(msg.sender));
    }

    /// @notice Withdraw the caller's credited balance to an address of the
    ///         caller's choice. This is the escape hatch for a beneficiary
    ///         that can call the board but cannot receive BNB itself (e.g.
    ///         a contract without receive/fallback): it can redirect its
    ///         credit to an address it controls. Only the caller's own
    ///         credit is debited; the recipient cannot be the zero address
    ///         (a call to address(0) would succeed and burn the funds).
    ///         Same checks-effects-interactions + `nonReentrant` guarantees
    ///         as `withdraw()`.
    function withdrawTo(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        _withdrawTo(recipient);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice Read a single quest (reverts for unknown ids).
    function getQuest(uint256 questId) external view returns (Quest memory) {
        return _quest(questId);
    }

    /// @notice Page through quests, oldest first. The page length is
    ///         clamped to the remaining quests and to MAX_PAGE_SIZE (100);
    ///         frontends should page in small batches (e.g. 20).
    function getQuests(uint256 offset, uint256 limit)
        external
        view
        returns (Quest[] memory page, uint256 total)
    {
        total = questCount;
        if (offset >= total || limit == 0) return (new Quest[](0), total);
        uint256 remaining = total - offset;
        uint256 pageLength = limit > remaining ? remaining : limit;
        if (pageLength > MAX_PAGE_SIZE) pageLength = MAX_PAGE_SIZE;
        page = new Quest[](pageLength);
        for (uint256 i = 0; i < pageLength; i++) {
            page[i] = quests[offset + i];
        }
    }

    /// @notice Check whether an address holds an Agent ID.
    function isAgentIDHolder(address account) external view returns (bool) {
        return AGENT_ID.balanceOf(account) > 0;
    }

    /// @notice On-chain reputation of an address: quests posted, quests
    ///         completed as a worker, and total BNB earned.
    /// @dev Raw counts only. A completed count includes unilateral
    ///      timeout claims; it proves "tasks completed and paid", NOT
    ///      "the work was good". UIs must show raw numbers + history,
    ///      never a single unexplained score.
    function reputation(address account)
        external
        view
        returns (uint256 posted, uint256 completed, uint256 earned)
    {
        return (postedCount[account], completedCount[account], totalEarned[account]);
    }

    // ------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------

    function _quest(uint256 questId) internal view returns (Quest storage) {
        if (questId >= questCount) revert QuestDoesNotExist(questId);
        return quests[questId];
    }

    /// @dev Move `amount` from active escrow to `to`'s withdrawable
    ///      balance. Called only after the quest status is already
    ///      terminal (checks-effects-interactions). Never reverts on the
    ///      beneficiary's ability to receive BNB — that is the point of
    ///      pull-payment.
    function _credit(address to, uint256 amount) internal {
        totalEscrowed -= amount;
        pendingWithdrawals[to] += amount;
        totalPendingWithdrawals += amount;
    }

    /// @dev Shared withdrawal logic for `withdraw()` and `withdrawTo()`.
    ///      Only ever called from `nonReentrant` external functions.
    ///      Checks-effects-interactions: the caller's credit is zeroed
    ///      BEFORE the external call. On a failed transfer the whole call
    ///      reverts, restoring the credit in full. The `PaymentWithdrawn`
    ///      event names the credit owner (`msg.sender`), not the recipient.
    function _withdrawTo(address payable recipient) internal {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw(msg.sender);
        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed(recipient, amount);

        emit PaymentWithdrawn(msg.sender, amount);
    }

    /// @notice Reject plain BNB transfers so funds can never get stuck
    ///         outside the escrow accounting. (Forced BNB via SELFDESTRUCT
    ///         cannot be prevented, but it only ever ADDS surplus: the
    ///         accounting invariant is `balance >= totalEscrowed +
    ///         totalPendingWithdrawals`, and payouts always use the
    ///         per-quest `reward`, never the total balance.)
    receive() external payable {
        revert("Direct BNB transfers not accepted");
    }
}
