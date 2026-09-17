// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./ForkPin.sol";

import {PerpMeRamsesVenue, ISolidlyPair} from "../src/tax/venue/PerpMeRamsesVenue.sol";

interface IFactoryLike {
    function getPair(address, address, bool) external view returns (address);
}

/**
 * The Ramses adapter against Ramses itself, on a fork of HyperEVM.
 *
 * Every pair below is a real one, chosen for what it proves rather than for
 * being convenient. Their fees are 0.3%, 1% and 2%, which is the whole point:
 * an adapter that had a fee written into it could be right for at most one of
 * them, and this one has no fee in it at all.
 */
contract RamsesVenueTest is Test {
    address constant FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;

    /// 1% fee, and traded enough to have a real price history.
    address constant PAIR_1PCT = 0x04c8702fa0853aa77021880C8e7Db8CDb69B59f6;
    address constant HYPERRAM = 0x5555c2542836e7a6c8D3E133D5AA9773b65D5555;
    /// 2% fee — four times what a coin compiled against Uniswap V2 would assume.
    address constant PAIR_2PCT = 0xb146f0959F1Fc97bCE7600dcfc5C34caf0bd28c3;
    address constant USDH = 0x111111a1a0667d36bD57c0A9f569b98057111111;
    /// 0.3%, and barely traded: three observations, too few to average.
    address constant PAIR_YOUNG = 0x4378d5838193Fdc3ed256F6C9d37dcde2c3a60CD;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    PerpMeRamsesVenue venue;

    function setUp() public {
        ForkPin.select();
        venue = new PerpMeRamsesVenue(FACTORY);
    }

    /// The number the coin sells against is the pair's own, whatever it charges.
    function test_amountOutMatchesThePairAtAnyFee() public view {
        uint256 probe = 1e18;

        assertEq(
            venue.amountOut(PAIR_1PCT, HYPERRAM, probe),
            ISolidlyPair(PAIR_1PCT).getAmountOut(probe, HYPERRAM),
            "1% pair"
        );
        assertEq(
            venue.amountOut(PAIR_2PCT, USDH, probe),
            ISolidlyPair(PAIR_2PCT).getAmountOut(probe, USDH),
            "2% pair, and the adapter never learned what 2% is"
        );
        assertGt(venue.amountOut(PAIR_1PCT, HYPERRAM, probe), 0, "a real quote");
    }

    /// A pair with a history is judged against it and passes.
    function test_priceIsSaneOnATradedPair() public {
        vm.prank(HYPERRAM);
        assertTrue(venue.priceIsSane(PAIR_1PCT), "an untouched pool quotes its own average");
    }

    /**
     * A pair too young to have been averaged is refused rather than trusted.
     *
     * This one has three observations. Asking a Solidly pair to average over
     * more than it holds does not return something worse, it reverts — which is
     * exactly the case a sale must survive without taking the trade down with
     * it.
     */
    function test_priceIsSaneRefusesAPairWithNoHistory() public {
        assertLe(ISolidlyPair(PAIR_YOUNG).observationLength(), 4, "still young, or pick another");
        vm.prank(USDC);
        assertFalse(venue.priceIsSane(PAIR_YOUNG), "nothing to average over yet");
    }

    /// Nothing about a wrong address reaches the caller as an exception.
    function test_rubbishAddressesAnswerRatherThanRevert() public {
        address notAPair = address(0xBADBAD);
        assertEq(venue.amountOut(notAPair, USDC, 1e18), 0, "no quote");
        vm.prank(USDC);
        assertFalse(venue.priceIsSane(notAPair), "and not sane");
    }

    /// An existing pair is found rather than created a second time.
    function test_openPairFindsTheOneThatExists() public {
        address found = venue.openPair(USDC, USDT0);
        assertEq(found, PAIR_YOUNG, "the volatile pair Ramses already has");
        assertEq(
            IFactoryLike(FACTORY).getPair(USDC, USDT0, false),
            found,
            "and it is the one the factory names"
        );
    }

    /// A pair that does not exist yet is created, with the volatile curve.
    function test_openPairCreatesAVolatileOne() public {
        address a = address(new Dummy());
        address b = address(new Dummy());
        assertEq(IFactoryLike(FACTORY).getPair(a, b, false), address(0), "none yet");

        address pair = venue.openPair(a, b);
        assertTrue(pair != address(0), "created");
        assertEq(IFactoryLike(FACTORY).getPair(a, b, false), pair, "as the volatile pair");
        assertEq(IFactoryLike(FACTORY).getPair(a, b, true), address(0), "and not the stable one");

        assertEq(venue.openPair(a, b), pair, "asking twice does not make a second");
    }
}

/// @dev Enough of an ERC20 for a Solidly factory to name the pair it makes:
///      it reads the symbol of both sides to build "Volatile AMM - A/B".
contract Dummy {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        return "DUM";
    }

    function name() external pure returns (string memory) {
        return "Dummy";
    }
}
