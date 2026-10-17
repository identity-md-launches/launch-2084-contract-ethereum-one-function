// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Models the v4 lock and debt/credit settlement, with programmable fills for edge cases.
/// The separate integration suite also executes the vendored real PoolManager and swap math.
contract MockPoolManager {
    using SafeERC20 for IERC20;

    address public locker;
    uint256 public debt;
    uint256 public credit;
    Currency public synced;
    PoolKey public lastKey;
    IPoolManager.SwapParams public lastParams;
    bytes public lastHookData;
    uint256 public swaps;
    uint256 public totalSettled;
    uint128 public output;
    uint16 public fillBps;
    bool public shortTransfer;
    bool public skipCallback;
    bool public doubleCallback;

    function configure(uint128 output_, uint16 fillBps_) external {
        output = output_;
        fillBps = fillBps_;
    }

    function configureFaults(bool shortTransfer_, bool skipCallback_, bool doubleCallback_) external {
        shortTransfer = shortTransfer_;
        skipCallback = skipCallback_;
        doubleCallback = doubleCallback_;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "manager locked");
        locker = msg.sender;
        if (skipCallback) result = abi.encode(uint256(output));
        else result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (doubleCallback) IUnlockCallback(msg.sender).unlockCallback(data);
        require(debt == 0 && credit == 0, "currency not settled");
        locker = address(0);
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == locker, "not locker");
        require(params.amountSpecified < 0 && params.zeroForOne, "not exact ETH input");
        lastKey = key;
        lastParams = params;
        lastHookData = hookData;
        ++swaps;
        debt = uint256(-params.amountSpecified) * fillBps / 10_000;
        credit = output;
        return toBalanceDelta(-int128(int256(debt)), int128(output));
    }

    function sync(Currency currency) external {
        synced = currency;
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == locker, "not locker");
        require(Currency.unwrap(synced) == address(0), "native currency not synced");
        require(msg.value == debt, "wrong debt payment");
        debt = 0;
        totalSettled += msg.value;
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(msg.sender == locker, "not locker");
        require(currency == lastKey.currency1 && amount == credit, "wrong credit");
        credit = 0;
        IERC20(Currency.unwrap(currency)).safeTransfer(to, shortTransfer ? amount - 1 : amount);
    }
}
