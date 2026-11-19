// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal stand-in for the SPACE ID Agent ID ERC-721.
/// @dev Only `balanceOf` matters to AgentQuestBoard. Tests grant/revoke
///      holder status with `mint` / `burn`. In unit tests the mock's
///      runtime code is etched at the canonical registry address
///      (0x60B9…022F) so the board's hardcoded registry resolves to it.
contract MockAgentID {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] = 1;
    }

    function mintMany(address to, uint256 amount) external {
        balanceOf[to] = amount;
    }

    function burn(address from) external {
        balanceOf[from] = 0;
    }
}

/// @notice Attacker that tries to re-enter `withdraw()` from its receive
///         function. A correct board must never pay twice.
///
/// @dev Actual behavior (asserted by the test): the inner `withdraw()` call
///      reverts (nonReentrant guard), the outer `withdraw()` still succeeds
///      exactly once — the attacker is paid for the real work, never twice.
///      Note the board's settlement functions (`confirmCompletion` etc.) do
///      NOT transfer BNB at all (pull-payment: they only credit a balance),
///      so `withdraw()` is the only external-call surface and the only
///      place re-entrancy can be attempted.
contract ReentrantWorker {
    address public board;
    uint256 public calls;

    constructor(address _board) {
        board = _board;
    }

    receive() external payable {
        calls++;
        // Attempt re-entry into withdraw(): must fail (nonReentrant), which
        // leaves the outer withdraw unaffected — it still pays exactly once.
        (bool ok,) = board.call(abi.encodeWithSignature("withdraw()"));
        // Deliberately ignore `ok`: if re-entry were possible, `ok` would
        // be true and the attacker would drain the board. The test asserts
        // the attacker is paid exactly once and its pending balance is 0.
        ok;
    }
}

/// @notice Contract that cannot receive BNB at all (no receive, no
///         fallback). Used to prove that an unpayable poster/worker can
///         never block anyone else's settlement under pull-payment: the
///         credit always succeeds, only its own `withdraw()` reverts.
contract UnpayableWorker {
    // Intentionally empty: any BNB transfer to this contract reverts.
}
