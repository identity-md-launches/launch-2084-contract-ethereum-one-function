// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Adds liquidity and trades in either direction against the real PoolManager, settling every delta.
contract PoolActor is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function addLiquidity(PoolKey calldata key, int24 lower, int24 upper, int256 amount) external {
        manager.unlock(abi.encode(true, key, lower, upper, amount, false));
    }

    function trade(PoolKey calldata key, bool zeroForOne, int256 amountIn) external {
        manager.unlock(abi.encode(false, key, int24(0), int24(0), amountIn, zeroForOne));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (bool liquidity, PoolKey memory key, int24 lower, int24 upper, int256 amount, bool zeroForOne) =
            abi.decode(data, (bool, PoolKey, int24, int24, int256, bool));
        BalanceDelta delta;
        if (liquidity) {
            (delta,) =
                manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, amount, bytes32(0)), "");
        } else {
            delta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -amount,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        }
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

    receive() external payable {}
}

contract RealPoolHandler is Test {
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    WebsiteBuyer public buyer;
    IPoolManager public manager;
    MockIntake public intake;
    PoolActor public trader;
    address[] public buyers;

    uint256 public ghostEthIn;
    uint256 public ghostPricePaid;
    uint256 public okBuys;
    uint256 public shortBuys;
    mapping(address => uint256) public surplusOf;

    constructor(WebsiteBuyer buyer_, IPoolManager manager_, MockIntake intake_, PoolActor trader_) {
        buyer = buyer_;
        manager = manager_;
        intake = intake_;
        trader = trader_;
        buyers.push(makeAddr("real-a"));
        buyers.push(makeAddr("real-b"));
        for (uint256 i; i < buyers.length; ++i) {
            vm.deal(buyers[i], 1_000 ether);
        }
    }

    function buyerCount() external view returns (uint256) {
        return buyers.length;
    }

    function buy(uint256 who, uint256 ethSeed, uint256 priceSeed) external {
        address user = buyers[who % buyers.length];
        uint256 eth = bound(ethSeed, 1, 10 ether);
        uint256 price = bound(priceSeed, 1, 2 ether);
        intake.setPrice(buyer.JOB_OPEN(), IMD, price);
        uint256 poolIMD = IERC20(IMD).balanceOf(address(manager));
        uint256 userEth = user.balance;
        uint256 userImd = IERC20(IMD).balanceOf(user);

        vm.prank(user);
        try buyer.buyWebsite{value: eth}("a real pool purchase") {
            uint256 output = poolIMD - IERC20(IMD).balanceOf(address(manager));
            assertGe(output, price, "paid with less than the live price");
            assertEq(IERC20(IMD).balanceOf(user) - userImd, output - price, "surplus not returned");
            assertEq(userEth - user.balance, eth, "not all ETH swapped");
            ghostEthIn += eth;
            ghostPricePaid += price;
            surplusOf[user] += output - price;
            ++okBuys;
        } catch (bytes memory err) {
            // Acceptable refusals: output below the live price, or a dust/out-of-range input the pool
            // cannot fill completely (zero output or a partial fill). Nothing else.
            bytes4 reason = bytes4(err);
            assertTrue(
                reason == WebsiteBuyer.InsufficientIMD.selector || reason == WebsiteBuyer.IncompleteSwap.selector,
                "unexpected refusal"
            );
            assertEq(user.balance, userEth);
            assertEq(IERC20(IMD).balanceOf(address(manager)), poolIMD);
            ++shortBuys;
        }
    }

    /// @dev Another trader moves the pool price either way between purchases.
    function moveMarket(bool zeroForOne, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0.01 ether, 50 ether);
        trader.trade(buyer.poolKey(), zeroForOne, int256(amount));
    }
}

contract RealPoolInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint256 internal constant SUPPLY = 10_000_000 ether;

    WebsiteBuyer internal buyer;
    MockIMD internal imd;
    IPoolManager internal manager;
    PoolActor internal provider;
    PoolActor internal trader;
    RealPoolHandler internal handler;
    address internal treasury;
    uint256 internal ethTotal;

    function setUp() public {
        vm.chainId(1);
        treasury = makeAddr("treasury");
        deployCodeTo("MockIMD.sol:MockIMD", IMD);
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(OWNER), MANAGER);
        imd = MockIMD(IMD);
        manager = IPoolManager(MANAGER);
        MockIntake(INTAKE).configure(treasury, makeAddr("writer"), bytes32("job.open@job-1"), IMD, 0.5 ether);
        buyer = new WebsiteBuyer(OWNER);
        manager.initialize(buyer.poolKey(), uint160(1 << 96));
        provider = new PoolActor(manager);
        trader = new PoolActor(manager);
        imd.mint(address(provider), SUPPLY / 2);
        imd.mint(address(trader), SUPPLY / 2);
        vm.deal(address(provider), 1_000_000 ether);
        vm.deal(address(trader), 1_000_000 ether);
        provider.addLiquidity(buyer.poolKey(), -60_000, 60_000, 1_000 ether);
        handler = new RealPoolHandler(buyer, manager, MockIntake(INTAKE), trader);
        ethTotal = MANAGER.balance + address(provider).balance + address(trader).balance + 2_000 ether;

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.moveMarket.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_realPoolHubCustodyIsZeroAndManagerSettled() public view {
        assertEq(address(buyer).balance, 0);
        assertEq(imd.balanceOf(address(buyer)), 0);
        assertEq(manager.currencyDelta(address(buyer), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(buyer), Currency.wrap(IMD)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_realPoolValueConserved() public view {
        assertEq(imd.balanceOf(treasury), handler.ghostPricePaid());
        uint256 imdHeld = imd.balanceOf(MANAGER) + imd.balanceOf(treasury) + imd.balanceOf(address(provider))
            + imd.balanceOf(address(trader)) + imd.balanceOf(address(buyer)) + imd.balanceOf(INTAKE);
        uint256 ethHeld = MANAGER.balance + address(provider).balance + address(trader).balance + address(buyer).balance;
        for (uint256 i; i < handler.buyerCount(); ++i) {
            address user = handler.buyers(i);
            assertEq(imd.balanceOf(user), handler.surplusOf(user));
            imdHeld += imd.balanceOf(user) + imd.balanceOf(address(buyer.accountOf(user)));
            ethHeld += user.balance + address(buyer.accountOf(user)).balance;
        }
        assertEq(imdHeld, SUPPLY);
        assertEq(ethHeld, ethTotal);
    }
}
