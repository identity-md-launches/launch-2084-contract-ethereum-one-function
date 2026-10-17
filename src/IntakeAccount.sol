// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";

/// @notice A buyer's permanent payer identity. Only its buyer can execute arbitrary calls.
/// @dev Adapted from the supplied IntakeAccount: exact payment checks, explicit approval cleanup,
/// reentrancy guard, nonzero user, and payable execute added. Created only on first purchase.
contract IntakeAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotHub();
    error NotUser();
    error InvalidUser();
    error PaymentNotConsumed();

    address public immutable hub;
    address public immutable user;

    constructor(address user_) {
        if (user_ == address(0)) revert InvalidUser();
        hub = msg.sender;
        user = user_;
    }

    /// @notice Pays the Intake for one request from this account. The hub has just sent exactly
    /// `price` here; it is approved for this call and the Intake pulls it, so no allowance remains.
    function ask(
        IIntake intake,
        bytes32 action,
        bytes calldata body,
        IIntake.Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 price
    ) external nonReentrant returns (bytes32 requestId) {
        if (msg.sender != hub) revert NotHub();
        IERC20 token = IERC20(asset);
        uint256 beforePayment = token.balanceOf(address(this));
        token.forceApprove(address(intake), price);
        requestId = intake.requestWithFailure(action, body, callback, onFailure, asset, price);
        token.forceApprove(address(intake), 0);
        if (beforePayment < price || token.balanceOf(address(this)) != beforePayment - price) {
            revert PaymentNotConsumed();
        }
    }

    /// @notice The user acting as the payer: any call, with value, from this account.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        nonReentrant
        returns (bytes memory result)
    {
        if (msg.sender != user) revert NotUser();
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @notice A launch pool pays its requester's LP fee share in ETH as well as in tokens.
    receive() external payable {}
}

