// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {IntakeAccount} from "../src/IntakeAccount.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Drives WebsiteBuyer through random sequences of purchases (good and bad), result and failure
/// deliveries, spoofed callbacks, pauses, Intake migrations, donations and unauthorised admin calls.
/// Every expected revert is caught and its reason checked, so the runner's fail_on_revert stays on.
contract WebsiteBuyerHandler is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bytes32 internal constant JOB_OPEN = bytes32("job.open@job-1");
    uint256 internal constant START_ETH = 1_000 ether;

    struct Ghost {
        address buyer;
        address intake;
        uint256 price;
        uint8 state; // mirrors WebsiteBuyer.State
        uint8 status;
        bytes32 resultHash;
        bytes32 reason;
        bytes32 uriHash;
        bool completedAtIntake;
    }

    WebsiteBuyer public buyer;
    MockIMD public imd;
    MockPoolManager public manager;
    address public owner;
    address public writer;
    address public treasury;

    MockIntake[] public intakes;
    MockIntake public current;
    address[] public actors;

    // Ghost accounting.
    uint256 public ghostEthIn;
    uint256 public ghostPricePaid;
    uint256 public ghostDonated;
    mapping(address => uint256) public ethSpent;
    mapping(address => uint256) public surplusOf;
    mapping(address => address) public firstAccount;
    bytes32[] public ids;
    mapping(bytes32 => Ghost) internal _ghosts;

    // Call counters, so a run that never exercised a path is visible.
    uint256 public okBuys;
    uint256 public refusedBuys;
    uint256 public results;
    uint256 public failures;
    uint256 public undelivered;

    constructor(
        WebsiteBuyer buyer_,
        MockIMD imd_,
        MockPoolManager manager_,
        MockIntake intake_,
        address owner_,
        address writer_,
        address treasury_
    ) {
        buyer = buyer_;
        imd = imd_;
        manager = manager_;
        owner = owner_;
        writer = writer_;
        treasury = treasury_;
        current = intake_;
        intakes.push(intake_);
        actors.push(makeAddr("actor-a"));
        actors.push(makeAddr("actor-b"));
        actors.push(makeAddr("actor-c"));
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], START_ETH);
        }
    }

    // ---------------------------------------------------------------- views for invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function intakeCount() external view returns (uint256) {
        return intakes.length;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function ghostOf(bytes32 id) external view returns (Ghost memory) {
        return _ghosts[id];
    }

    // ---------------------------------------------------------------- actions

    function buy(uint256 actorSeed, uint256 ethSeed, uint256 outSeed, uint256 priceSeed, uint256 wordSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 eth = bound(ethSeed, 1, 10 ether);
        uint128 out = uint128(bound(outSeed, 1, 5 ether));
        // One in eight purchases meets an unsold action; otherwise the price may exceed the output.
        uint256 price = priceSeed % 8 == 0 ? 0 : bound(priceSeed, 1, 3 ether);
        manager.configure(out, 10_000);
        current.setPrice(JOB_OPEN, IMD, price);
        string memory words = _words(wordSeed);

        bool paused = buyer.paused();
        bytes memory expected;
        if (paused) expected = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        else if (price == 0) expected = abi.encodeWithSelector(WebsiteBuyer.ActionNotSold.selector);
        else if (out < price) expected = abi.encodeWithSelector(WebsiteBuyer.InsufficientIMD.selector, out, price);

        _attempt(actor, eth, words, expected, out, price);
    }

    function buyPartialFill(uint256 actorSeed, uint256 ethSeed, uint16 fillSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 eth = bound(ethSeed, 2, 10 ether);
        uint16 fill = uint16(bound(fillSeed, 0, 9_999));
        manager.configure(5 ether, fill);
        current.setPrice(JOB_OPEN, IMD, 0.5 ether);
        bytes memory expected = buyer.paused()
            ? abi.encodeWithSelector(Pausable.EnforcedPause.selector)
            : abi.encodeWithSelector(WebsiteBuyer.IncompleteSwap.selector);
        _attempt(actor, eth, "a partial fill must not charge", expected, 0, 0);
        manager.configure(5 ether, 10_000);
    }

    function buyBadWords(uint256 actorSeed, uint8 kind, uint16 lenSeed) external {
        address actor = actors[actorSeed % actors.length];
        current.setPrice(JOB_OPEN, IMD, 0.5 ether);
        bytes memory words;
        uint256 k = kind % 4;
        if (k == 0) {
            words = "";
        } else if (k == 1) {
            words = new bytes(bound(lenSeed, 1001, 3000));
            for (uint256 i; i < words.length; ++i) {
                words[i] = "w";
            }
        } else {
            uint256 len = bound(lenSeed, 1, 1000);
            words = new bytes(len);
            for (uint256 i; i < len; ++i) {
                words[i] = "w";
            }
            bytes1 bad = k == 2 ? bytes1(uint8(lenSeed % 32)) : (lenSeed % 2 == 0 ? bytes1(0x22) : bytes1(0x5c));
            words[lenSeed % len] = bad;
        }
        bytes memory expected = buyer.paused()
            ? abi.encodeWithSelector(Pausable.EnforcedPause.selector)
            : abi.encodeWithSelector(WebsiteBuyer.BadWords.selector);
        _attempt(actor, 1 ether, string(words), expected, 0, 0);
    }

    function deliverResult(uint256 idSeed, uint256 hashSeed, uint8 uriLen) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        Ghost storage g = _ghosts[id];
        if (g.completedAtIntake) return;
        bytes32 hash = keccak256(abi.encode(hashSeed));
        string memory uri = _uri(uint256(uriLen) % 97);
        vm.prank(writer);
        bool delivered = MockIntake(g.intake).complete(id, 0, abi.encode(id, hash, uri));
        g.completedAtIntake = true;
        assertTrue(delivered, "pending result must be delivered within the stipend");
        g.state = uint8(WebsiteBuyer.State.Done);
        g.resultHash = hash;
        g.uriHash = keccak256(bytes(uri));
        ++results;
    }

    function deliverFailure(uint256 idSeed, uint8 statusSeed, bytes32 reason) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        Ghost storage g = _ghosts[id];
        if (g.completedAtIntake) return;
        // Mostly 1 or 2; sometimes a status the contract must refuse, which the Intake records undelivered.
        uint8 status = statusSeed % 5 == 4 ? uint8(bound(statusSeed, 3, 255)) : uint8(statusSeed % 2 + 1);
        vm.prank(writer);
        bool delivered =
            MockIntake(g.intake).complete(id, status, abi.encode(id, status, reason, uint16(0), uint16(0), bytes("")));
        g.completedAtIntake = true;
        if (status == 1 || status == 2) {
            assertTrue(delivered, "pending failure must be delivered");
            g.state = uint8(WebsiteBuyer.State.Failed);
            g.status = status;
            g.reason = reason;
            ++failures;
        } else {
            assertFalse(delivered, "unknown status must not settle");
            ++undelivered;
        }
    }

    /// @dev A caller that is not the request's Intake, or any caller once settled, is refused.
    function spoofCallback(uint256 idSeed, uint256 senderSeed, bool asResult) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        Ghost storage g = _ghosts[id];
        address sender;
        uint256 pick = senderSeed % 4;
        if (pick == 0) sender = actors[senderSeed % actors.length];
        else if (pick == 1) sender = writer;
        else if (pick == 2) sender = owner;
        else sender = g.intake; // allowed only while pending; spoof it only once settled
        if (sender == g.intake && g.state == uint8(WebsiteBuyer.State.Pending)) sender = g.buyer;

        vm.prank(sender);
        if (asResult) {
            try buyer.onIntakeResult(id, keccak256("forged"), "ipfs://forged") {
                assertTrue(false, "spoofed result accepted");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
            }
        } else {
            try buyer.onIntakeFailure(id, 1, bytes32("forged"), 0, 0, "") {
                assertTrue(false, "spoofed failure accepted");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
            }
        }
    }

    function spoofUnknownRequest(bytes32 id, bool asResult) external {
        if (_ghosts[id].buyer != address(0)) return;
        vm.prank(address(current));
        if (asResult) {
            try buyer.onIntakeResult(id, bytes32(0), "") {
                assertTrue(false, "unknown result accepted");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
            }
        } else {
            try buyer.onIntakeFailure(id, 2, bytes32("failed"), 0, 0, "") {
                assertTrue(false, "unknown failure accepted");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
            }
        }
    }

    function togglePause() external {
        bool paused = buyer.paused();
        vm.prank(owner);
        buyer.setPaused(!paused);
        assertEq(buyer.paused(), !paused);
    }

    function migrateIntake(uint256 seed) external {
        MockIntake next;
        if (intakes.length < 3 && seed % 2 == 0) {
            next = new MockIntake();
            next.configure(treasury, writer, JOB_OPEN, IMD, 0.5 ether);
            intakes.push(next);
        } else {
            next = intakes[seed % intakes.length];
        }
        vm.prank(owner);
        buyer.setIntake(IIntake(address(next)));
        current = next;
        assertEq(address(buyer.intake()), address(next));
    }

    function outsiderAdmin(uint256 actorSeed, bool pause) external {
        address actor = actors[actorSeed % actors.length];
        bytes memory expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor);
        bool next = !buyer.paused();
        IIntake target = IIntake(address(intakes[actorSeed % intakes.length]));
        vm.prank(actor);
        if (pause) {
            try buyer.setPaused(next) {
                assertTrue(false, "outsider paused");
            } catch (bytes memory err) {
                assertEq(err, expected);
            }
        } else {
            try buyer.setIntake(target) {
                assertTrue(false, "outsider changed intake");
            } catch (bytes memory err) {
                assertEq(err, expected);
            }
        }
    }

    /// @dev Someone sends IMD straight to the hub. It cannot help a purchase and must never be paid out.
    function donateIMD(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        imd.mint(address(buyer), amount);
        ghostDonated += amount;
    }

    function donateETH(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1 ether);
        vm.prank(actor);
        (bool ok,) = address(buyer).call{value: amount}("");
        assertFalse(ok, "hub accepted a plain ETH transfer");
    }

    // ---------------------------------------------------------------- helpers

    function _attempt(
        address actor,
        uint256 eth,
        string memory words,
        bytes memory expected,
        uint128 out,
        uint256 price
    ) internal {
        uint256 actorEth = actor.balance;
        uint256 actorImd = imd.balanceOf(actor);
        uint256 treasuryImd = imd.balanceOf(treasury);
        address accountBefore = address(buyer.accountOf(actor));
        MockIntake used = current;

        vm.prank(actor);
        try buyer.buyWebsite{value: eth}(words) returns (bytes32 id) {
            assertEq(expected.length, 0, "purchase that must revert succeeded");
            assertEq(_ghosts[id].buyer, address(0), "request id reused");
            ghostEthIn += eth;
            ethSpent[actor] += eth;
            ghostPricePaid += price;
            surplusOf[actor] += out - price;
            address account = address(buyer.accountOf(actor));
            if (firstAccount[actor] == address(0)) firstAccount[actor] = account;
            ids.push(id);
            _ghosts[id] =
                Ghost(actor, address(used), price, uint8(WebsiteBuyer.State.Pending), 0, 0, 0, keccak256(""), false);
            // The body that reached the Intake is exactly the preview, with no owner field.
            assertEq(used.requestOf(id).body, buyer.bodyOf(words));
            ++okBuys;
        } catch (bytes memory err) {
            assertGt(expected.length, 0, "valid purchase reverted");
            assertEq(err, expected, "wrong revert reason");
            assertEq(actor.balance, actorEth, "refused purchase kept ETH");
            assertEq(imd.balanceOf(actor), actorImd, "refused purchase moved IMD");
            assertEq(imd.balanceOf(treasury), treasuryImd, "refused purchase paid the Intake");
            assertEq(address(buyer.accountOf(actor)), accountBefore, "refused purchase opened an account");
            ++refusedBuys;
        }
    }

    function _words(uint256 seed) internal pure returns (string memory) {
        uint256 pick = seed % 5;
        if (pick == 0) return "x";
        if (pick == 1) return "a bakery in Lisbon";
        if (pick == 2) return unicode"Café menu — 東京";
        if (pick == 3) return "portfolio for a jazz trio, dark theme, contact form";
        bytes memory w = new bytes(1000);
        for (uint256 i; i < w.length; ++i) {
            w[i] = bytes1(uint8(0x61 + (seed >> 8 + i % 64) % 26));
        }
        return string(w);
    }

    function _uri(uint256 len) internal pure returns (string memory) {
        bytes memory u = new bytes(len);
        for (uint256 i; i < len; ++i) {
            u[i] = "u";
        }
        return string(u);
    }
}

contract WebsiteBuyerInvariantTest is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    bytes32 internal constant JOB_OPEN = bytes32("job.open@job-1");
    uint256 internal constant POOL_IMD = 1_000_000 ether;

    WebsiteBuyer internal buyer;
    MockIMD internal imd;
    MockPoolManager internal manager;
    WebsiteBuyerHandler internal handler;
    address internal treasury;

    function setUp() public {
        vm.chainId(1);
        treasury = makeAddr("treasury");
        address writer = makeAddr("writer");
        deployCodeTo("MockIMD.sol:MockIMD", IMD);
        deployCodeTo("MockPoolManager.sol:MockPoolManager", MANAGER);
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        imd = MockIMD(IMD);
        manager = MockPoolManager(MANAGER);
        MockIntake(INTAKE).configure(treasury, writer, JOB_OPEN, IMD, 0.5 ether);
        manager.configure(2 ether, 10_000);
        imd.mint(MANAGER, POOL_IMD);
        buyer = new WebsiteBuyer(OWNER);
        handler = new WebsiteBuyerHandler(buyer, imd, manager, MockIntake(INTAKE), OWNER, writer, treasury);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.buy.selector; // weighted: purchases drive the state the others act on
        selectors[2] = handler.buyPartialFill.selector;
        selectors[3] = handler.buyBadWords.selector;
        selectors[4] = handler.deliverResult.selector;
        selectors[5] = handler.deliverFailure.selector;
        selectors[6] = handler.spoofCallback.selector;
        selectors[7] = handler.spoofUnknownRequest.selector;
        selectors[8] = handler.togglePause.selector;
        selectors[9] = handler.migrateIntake.selector;
        selectors[10] = handler.outsiderAdmin.selector;
        selectors[11] = handler.donateIMD.selector;
        selectors[12] = handler.donateETH.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_hubNeverHoldsETH() public view {
        assertEq(address(buyer).balance, 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_hubIMDIsOnlyWhatWasDonated() public view {
        assertEq(imd.balanceOf(address(buyer)), handler.ghostDonated());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_everyWeiSentReachedThePool() public view {
        assertEq(MANAGER.balance, handler.ghostEthIn());
        assertEq(manager.totalSettled(), handler.ghostEthIn());
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(actor.balance, 1_000 ether - handler.ethSpent(actor));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_imdConservedTreasuryGetsPricesBuyersGetSurplus() public view {
        assertEq(imd.balanceOf(treasury), handler.ghostPricePaid(), "treasury");
        uint256 held = imd.balanceOf(MANAGER) + imd.balanceOf(treasury) + imd.balanceOf(address(buyer));
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(imd.balanceOf(actor), handler.surplusOf(actor), "buyer surplus");
            held += imd.balanceOf(actor);
            held += imd.balanceOf(address(buyer.accountOf(actor)));
        }
        for (uint256 j; j < handler.intakeCount(); ++j) {
            held += imd.balanceOf(address(handler.intakes(j)));
        }
        assertEq(held, POOL_IMD + handler.ghostDonated(), "IMD created or destroyed");
        assertEq(imd.totalSupply(), POOL_IMD + handler.ghostDonated());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_accountsHoldNothingApproveNothingAndNeverChange() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            IntakeAccount account = buyer.accountOf(actor);
            assertEq(address(account), handler.firstAccount(actor), "account replaced");
            if (address(account) == address(0)) continue;
            assertEq(account.user(), actor);
            assertEq(account.hub(), address(buyer));
            assertEq(imd.balanceOf(address(account)), 0);
            assertEq(address(account).balance, 0);
            for (uint256 j; j < handler.intakeCount(); ++j) {
                assertEq(imd.allowance(address(account), address(handler.intakes(j))), 0);
            }
            for (uint256 k = i + 1; k < handler.actorCount(); ++k) {
                IntakeAccount other = buyer.accountOf(handler.actors(k));
                if (address(other) != address(0)) assertNotEq(address(other), address(account));
            }
        }
        for (uint256 j; j < handler.intakeCount(); ++j) {
            assertEq(imd.allowance(address(buyer), address(handler.intakes(j))), 0);
            assertEq(imd.balanceOf(address(handler.intakes(j))), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_poolManagerSettledAndUnlocked() public view {
        assertEq(manager.debt(), 0);
        assertEq(manager.credit(), 0);
        assertEq(manager.locker(), address(0));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_recordsMatchPaymentsAndSettleOnce() public view {
        uint256 pending;
        for (uint256 i; i < handler.idCount(); ++i) {
            bytes32 id = handler.ids(i);
            WebsiteBuyerHandler.Ghost memory g = handler.ghostOf(id);
            WebsiteBuyer.Request memory r = buyer.requestOf(id);
            assertEq(r.buyer, g.buyer, "buyer");
            assertEq(r.intake, g.intake, "intake");
            assertEq(r.price, g.price, "price");
            assertEq(uint8(r.state), g.state, "state");
            assertEq(r.status, g.status, "status");
            assertEq(r.resultHash, g.resultHash, "hash");
            assertEq(r.reason, g.reason, "reason");
            assertEq(keccak256(bytes(r.uri)), g.uriHash, "uri");
            if (g.state == uint8(WebsiteBuyer.State.Pending)) ++pending;
            MockIntake.StoredRequest memory sent = MockIntake(g.intake).requestOf(id);
            assertEq(sent.payer, address(buyer.accountOf(g.buyer)), "paid through own account");
            assertEq(sent.amount, g.price, "paid exactly the live price");
            assertEq(sent.callback.target, address(buyer));
        }
        assertEq(handler.okBuys(), handler.idCount());
        assertEq(handler.okBuys(), pending + handler.results() + handler.failures());
    }
}
