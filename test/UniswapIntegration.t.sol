// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Local test liquidity provider; uses actual v4 modifyLiquidity, settlement, and swap accounting.
contract LiquiditySeeder is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function add(PoolKey calldata key, int24 lower, int24 upper, int256 amount) external payable {
        manager.unlock(abi.encode(key, lower, upper, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 lower, int24 upper, int256 amount) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, amount, bytes32(0)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), owed);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}

/// @dev A searcher that front-runs a purchase with its own ETH to IMD swap on the same pool.
contract FrontRunner is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_, PoolKey memory key_) {
        manager = manager_;
        key = key_;
    }

    function swapIn(uint256 amount) external payable {
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        uint256 amount = abi.decode(data, (uint256));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        manager.sync(key.currency0);
        manager.settle{value: uint256(-int256(delta.amount0()))}();
        manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        return "";
    }
}

/// @dev Calls sync and buy in the SAME transaction, so transient state really survives between them.
contract SyncThenBuyer {
    function buy(IPoolManager manager, WebsiteBuyer buyer, Currency erc20) external payable returns (bytes32) {
        manager.sync(erc20);
        return buyer.buyWebsite{value: msg.value}("a contract wallet website");
    }
}

contract UniswapIntegrationTest is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address private constant OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 private constant PRICE = 0.5 ether;

    WebsiteBuyer private buyer;
    MockIMD private imd;
    MockIntake private intake;
    IPoolManager private manager;
    LiquiditySeeder private seeder;
    address private alice;
    address private treasury;

    function setUp() public {
        vm.chainId(1);
        alice = makeAddr("alice");
        treasury = makeAddr("treasury");
        deployCodeTo("MockIMD.sol:MockIMD", IMD);
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        // Executes the upstream constructor AT the fixed address, correctly setting NoDelegateCall's immutable.
        // The real manager source is unmodified; no RPC, fork, or cached chain snapshot is required.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(OWNER), MANAGER);
        imd = MockIMD(IMD);
        intake = MockIntake(INTAKE);
        manager = IPoolManager(MANAGER);
        intake.configure(treasury, makeAddr("writer"), bytes32("job.open@job-1"), IMD, PRICE);
        buyer = new WebsiteBuyer(OWNER);
        manager.initialize(buyer.poolKey(), uint160(1 << 96));
        seeder = new LiquiditySeeder(manager);
        imd.mint(address(seeder), 1_000_000 ether);
        vm.deal(address(seeder), 1_000_000 ether);
        vm.deal(alice, 100 ether);
    }

    function test_realPoolSwapsPaysAndRefundsWithAllDeltasSettled() public {
        _liquidity();
        uint256 poolETH = MANAGER.balance;
        uint256 poolIMD = imd.balanceOf(MANAGER);
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: 1 ether}("a cafe menu");
        assertEq(MANAGER.balance - poolETH, 1 ether);
        uint256 output = poolIMD - imd.balanceOf(MANAGER);
        assertGt(output, PRICE);
        assertLt(output, 0.99 ether); // 1% fee plus positive price impact.
        assertEq(imd.balanceOf(alice), output - PRICE);
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(intake.requestOf(id).payer, address(buyer.accountOf(alice)));
        _assertClean(alice);
    }

    function testFuzz_realPoolConservation(uint96 input) public {
        _liquidity();
        uint256 amount = bound(input, 0.6 ether, 10 ether);
        uint256 poolETH = MANAGER.balance;
        uint256 poolIMD = imd.balanceOf(MANAGER);
        vm.prank(alice);
        buyer.buyWebsite{value: amount}("a sports club website");
        assertEq(MANAGER.balance - poolETH, amount);
        assertEq(poolIMD - imd.balanceOf(MANAGER), PRICE + imd.balanceOf(alice));
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(alice.balance, 100 ether - amount);
        _assertClean(alice);
    }

    function test_realPoolShortOutputRollsBackPoolPriceAndBalances() public {
        _liquidity();
        uint256 poolETH = MANAGER.balance;
        uint256 poolIMD = imd.balanceOf(MANAGER);
        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(PoolId.wrap(buyer.POOL_ID()));
        vm.prank(alice);
        vm.expectPartialRevert(WebsiteBuyer.InsufficientIMD.selector);
        buyer.buyWebsite{value: 0.1 ether}("a cafe menu");
        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(PoolId.wrap(buyer.POOL_ID()));
        assertEq(sqrtAfter, sqrtBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(MANAGER.balance, poolETH);
        assertEq(imd.balanceOf(MANAGER), poolIMD);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(alice.balance, 100 ether);
        assertEq(address(buyer.accountOf(alice)), address(0));
    }

    function test_realPoolPartialFillAtLiquidityBoundaryReverts() public {
        seeder.add(buyer.poolKey(), -200, 200, 1 ether);
        intake.setPrice(buyer.JOB_OPEN(), IMD, 1);
        uint256 poolETH = MANAGER.balance;
        uint256 poolIMD = imd.balanceOf(MANAGER);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
        buyer.buyWebsite{value: 1 ether}("a cafe menu");
        assertEq(MANAGER.balance, poolETH);
        assertEq(imd.balanceOf(MANAGER), poolIMD);
        assertEq(alice.balance, 100 ether);
        assertEq(intake.nonce(), 0);
    }

    function test_realPoolWithoutLiquidityCannotChargeBuyer() public {
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
        buyer.buyWebsite{value: 1 ether}("a cafe menu");
        assertEq(alice.balance, 100 ether);
        assertEq(MANAGER.balance, 0);
        assertEq(intake.nonce(), 0);
    }

    function test_realManagerStaleERC20SyncDoesNotBlockNativeSettlement() public {
        _liquidity();
        SyncThenBuyer wallet = new SyncThenBuyer();
        vm.deal(address(this), 1 ether);
        bytes32 id = wallet.buy{value: 1 ether}(manager, buyer, Currency.wrap(IMD));
        assertEq(buyer.requestOf(id).buyer, address(wallet));
        assertGt(imd.balanceOf(address(wallet)), 0);
        _assertClean(address(wallet));
    }

    function test_realPoolMultiplePurchasesDoNotAccumulateCustody() public {
        _liquidity();
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            buyer.buyWebsite{value: 1 ether}("a different one-page site");
            _assertClean(alice);
        }
        assertEq(intake.nonce(), 4);
        assertEq(imd.balanceOf(treasury), 4 * PRICE);
    }

    function test_realPoolSandwichIsRefusedByBuyerMinimum() public {
        _liquidity();
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        buyer.buyWebsite{value: 50 ether}("a bakery in Lisbon");
        uint256 quoted = imd.balanceOf(alice);
        assertGt(quoted, 40 ether);
        vm.revertToState(snapshot);

        FrontRunner searcher = new FrontRunner(manager, buyer.poolKey());
        vm.deal(address(searcher), 2000 ether);
        searcher.swapIn(2000 ether);

        uint256 minSurplus = quoted * 99 / 100;
        vm.prank(alice);
        vm.expectPartialRevert(WebsiteBuyer.SurplusTooLow.selector);
        buyer.buyWebsiteWithMinimum{value: 50 ether}("a bakery in Lisbon", minSurplus, block.timestamp);
        assertEq(alice.balance, 100 ether);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(intake.nonce(), 0);

        // The one-argument form has no such floor: the same purchase succeeds with a much smaller surplus.
        vm.prank(alice);
        buyer.buyWebsite{value: 50 ether}("a bakery in Lisbon");
        assertLt(imd.balanceOf(alice), minSurplus);
        _assertClean(alice);
    }

    function _liquidity() private {
        seeder.add(buyer.poolKey(), -60000, 60000, 1000 ether);
    }

    function _assertClean(address user) private view {
        assertEq(address(buyer).balance, 0);
        assertEq(imd.balanceOf(address(buyer)), 0);
        assertEq(imd.balanceOf(address(buyer.accountOf(user))), 0);
        assertEq(imd.allowance(address(buyer.accountOf(user)), INTAKE), 0);
        assertEq(manager.currencyDelta(address(buyer), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(buyer), Currency.wrap(IMD)), 0);
        assertFalse(manager.isUnlocked());
    }
}
