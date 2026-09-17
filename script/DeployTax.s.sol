// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMeTaxToken} from "../src/tax/PerpMeTaxToken.sol";
import {PerpMeTaxTokenDeployer} from "../src/tax/PerpMeTaxTokenDeployer.sol";
import {PerpMeTaxFactory} from "../src/tax/PerpMeTaxFactory.sol";
import {PerpMeUniV2Venue} from "../src/tax/venue/PerpMeUniV2Venue.sol";
import {PerpMeRamsesVenue} from "../src/tax/venue/PerpMeRamsesVenue.sol";
import {PerpMeCurveRouter} from "../src/tax/PerpMeCurveRouter.sol";
import {PerpMeMarketRouter} from "../src/tax/PerpMeMarketRouter.sol";

/// @title Dividend-coin launchpad deployment (Uniswap V2 + bonding curve).
///
/// @notice Deploys the second of the launchpad's two products: coins that keep
///         a slice of every trade and pay it to their holders in the tokenized
///         share they trade against. The V3 instant-listing stack is separate
///         and untouched — see DeployV2.s.sol for that one.
///
///         Two contracts, then one launch config per pair token.
///
/// @dev The deployer must know the factory and the factory must know the
///      deployer, which is circular. Resolved the way the V3 stack resolves the
///      same knot: the factory's address is predicted from the sender's nonce
///      (CREATE is deterministic), then asserted after deployment. If the
///      assertion ever fails, the sender sent a transaction between the two
///      deploys — rerun rather than patch around it.
///
///      ALWAYS with --force. forge 1.8.1 left this script's own artifact
///      stale after a change to PerpMeBridge.sol — the router had been rebuilt,
///      the script embedding it had not — and devtest got the OLD curve router
///      on 2026-09-13 with every other contract current. A cached build here is
///      a wrong contract on mainnet with nothing to show for it.
///
///      Dry run:
///        forge script script/DeployTax.s.sol --force --rpc-url hyperevm --sender <addr>
///      Broadcast (spends gas — YOU sign):
///        forge script script/DeployTax.s.sol --force --rpc-url hyperevm \
///          --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract DeployPerpMeTax is Script {
    /* The two exchanges a graduated coin can open its pair on, both verified
     * on chain 999 and both proved end to end on a fork (TaxCoinRouting,
     * TaxOnRamses). PRJX is dex 0 and the default; Ramses is dex 1. A third
     * exchange later is another venue contract plus `addDexConfig`, with no
     * redeploy of anything here.
     *
     * Overridable from the environment so a testnet run can point elsewhere,
     * but the defaults are the real thing — this used to default to
     * address(0) under a note saying no venue had been chosen, which meant a
     * deploy with the variables unset produced nothing. */
    address constant DEFAULT_PRJX_V2_FACTORY = 0xb0D032B6cC82e37488497781338f359cE8CC40e0;
    address constant DEFAULT_RAMSES_FACTORY = 0xd0a07E160511c40ccD5340e94660E9C9c01b0D27;
    /**
     * Nest's AMM factory — the Solidly-style one, not the Algebra side.
     *
     * Two things about it, both from the chain rather than from anybody's
     * word. It answers exactly the interface `PerpMeRamsesVenue` speaks —
     * `getPair`/`createPair` with the `stable` flag, and pairs that answer
     * `getAmountOut`, `quote` and `observationLength` — so the same venue
     * contract serves it with no new code. And it refuses `createPair` to
     * everyone but `PAIRS_CREATOR_ROLE` today, so a launch config pointing at
     * it would revert rather than lie dormant. Nest have said permissionless
     * creation lands in their 2.0 update, early October 2026; until it does,
     * the venue is registered and simply has no configs seeded against it.
     *
     * If 2.0 ships a NEW factory address, this constant is the one line to
     * change — ask them for it rather than assuming this one survives.
     */
    address constant DEFAULT_NEST_FACTORY = 0x889Fd0aDA8453C7619cD7f11E9029a1f0848Fdf5;
    /// The V3 router the site already uses; the curve router bridges through it.
    address constant DEFAULT_SWAP_ROUTER_02 = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;

    /// Wrapped NVIDIA xStock — the first pair token to open, and the one the
    /// product story is told with.
    address constant WNVDAX = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    /**
     * @dev The curve's shape, and where the numbers come from.
     *
     *      `virtualQuote / virtualToken` is the opening price, so a whole
     *      supply opens at virtualQuote * TOTAL_SUPPLY / virtualToken ≈ 13.5
     *      wNVDAx. At roughly $222 a share that is about $3,000 — deliberately
     *      the same opening valuation a V3 launch gets, so a creator choosing
     *      between the two products is not also choosing between two
     *      unrelated starting prices.
     *
     *      793.1M of the supply is sold on the curve and the remaining 206.9M
     *      is held back to open the pair with, alongside everything raised —
     *      about 41.7 wNVDAx, or $9,100, at a graduation valuation near
     *      $44,000.
     */
    uint256 constant VIRTUAL_TOKEN = 1_073_000_000e18;
    /// Priced 2026-09-10 through PRJX's QuoterV2, the same day and the same
    /// way as the table in AddTaxConfigs, so the two wNVDAx configs this opens
    /// and the one that script would have added agree to the wei.
    uint256 constant VIRTUAL_QUOTE = 14.4657e18;
    uint256 constant CURVE_TOKENS = 793_100_000e18;

    /// Platform's cut of each curve trade. The curve caps this at 300.
    uint16 constant CURVE_FEE_BPS = 150; // 1.5%
    /// Platform's cut of each coin's tax after graduation. The coin caps this
    /// at 2000, so this is the ceiling and cannot later be raised.
    uint16 constant PROTOCOL_FEE_BPS = 2000; // 20%

    /// PRJX's swap fee. Thirty basis points, in the pair's own bytecode,
    /// verified against a live pair rather than assumed. Ramses has no such
    /// constant — its fee lives on each pair and the venue asks for it.
    uint16 constant PRJX_FEE_BPS = 30;

    function run() external {
        address treasury = vm.envOr("TAX_TREASURY", msg.sender);
        uint256 launchFee = vm.envOr("TAX_LAUNCH_FEE", uint256(0));
        address prjxFactory = vm.envOr("PRJX_V2_FACTORY", DEFAULT_PRJX_V2_FACTORY);
        address ramsesFactory = vm.envOr("RAMSES_FACTORY", DEFAULT_RAMSES_FACTORY);
        address nestFactory = vm.envOr("NEST_FACTORY", DEFAULT_NEST_FACTORY);
        // Checked here rather than left to the first graduation months later.
        require(prjxFactory.code.length > 0, "PRJX_V2_FACTORY has no code on this chain");
        require(ramsesFactory.code.length > 0, "RAMSES_FACTORY has no code on this chain");
        require(nestFactory.code.length > 0, "NEST_FACTORY has no code on this chain");

        vm.startBroadcast();

        /*
         * The exchanges, as contracts, before anything that predicts an address.
         *
         * Everything that differs between one exchange and the next lives in
         * these rather than in the factory or the coin — which is why the
         * second one is one more line here, not a second launchpad.
         */
        PerpMeUniV2Venue prjx = new PerpMeUniV2Venue(prjxFactory, PRJX_FEE_BPS);
        PerpMeRamsesVenue ramses = new PerpMeRamsesVenue(ramsesFactory);
        /* Nest speaks the same dialect; one more instance, not one more
           contract. Registered now so the address exists to be granted a role
           or to be pointed at by a config the day creation opens. */
        PerpMeRamsesVenue nest = new PerpMeRamsesVenue(nestFactory);

        address predictedFactory = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        PerpMeTaxTokenDeployer deployer = new PerpMeTaxTokenDeployer(predictedFactory);
        PerpMeTaxFactory factory = new PerpMeTaxFactory(
            address(deployer), treasury, launchFee, PROTOCOL_FEE_BPS
        );
        require(address(factory) == predictedFactory, "nonce prediction failed; rerun");

        // Lets somebody holding HYPE trade a coin priced in a share. Without it
        // the audience for a fresh dividend coin is people who already own the
        // right stock token, which is close to nobody.
        PerpMeCurveRouter curveRouter =
            new PerpMeCurveRouter(DEFAULT_SWAP_ROUTER_02, WHYPE);
        factory.setCurveRouter(address(curveRouter));

        /* Its counterpart for after graduation. The factory does not hold it:
           a graduated coin's transfers are open, so this needs no permission
           from anybody — only the site has to know where it is. */
        PerpMeMarketRouter marketRouter =
            new PerpMeMarketRouter(DEFAULT_SWAP_ROUTER_02, WHYPE);

        uint256 prjxId = factory.addDexConfig(prjx, "prjx-v2");
        require(prjxId == 0, "PRJX must be dex 0: the site and the seed table assume it");
        uint256 ramsesId = factory.addDexConfig(ramses, "ramses");
        require(ramsesId == 1, "Ramses must be dex 1");
        uint256 nestId = factory.addDexConfig(nest, "nest");
        require(nestId == 2, "Nest must be dex 2: the site maps the picker by name");

        // One opening pair on each exchange. The rest of the table is
        // AddTaxConfigs, run afterwards against TAX_FACTORY_ADDRESS.
        uint256 configId = factory.addLaunchConfig(_nvda(prjxId));
        uint256 ramsesConfigId = factory.addLaunchConfig(_nvda(ramsesId));

        vm.stopBroadcast();

        console2.log("PerpMeTaxTokenDeployer ", address(deployer));
        console2.log("PerpMeTaxFactory       ", address(factory));
        console2.log("PerpMeCurveRouter      ", address(curveRouter));
        console2.log("PerpMeMarketRouter     ", address(marketRouter));
        console2.log("treasury                ", treasury);
        console2.log("PerpMeUniV2Venue (PRJX) ", address(prjx));
        console2.log("PerpMeRamsesVenue       ", address(ramses));
        console2.log("PerpMeNestVenue (same)  ", address(nest));
        console2.log("launch config, PRJX     ", configId);
        console2.log("launch config, Ramses   ", ramsesConfigId);
        console2.log("  pair token            ", WNVDAX);
        console2.log("coin init code hash     ");
        console2.logBytes32(deployer.INIT_CODE_HASH());
    }

    function _nvda(uint256 dexId) internal pure returns (PerpMeTaxFactory.LaunchConfig memory) {
        return PerpMeTaxFactory.LaunchConfig({
            dexId: dexId,
            pairToken: WNVDAX,
            totalSupply: TOTAL_SUPPLY,
            enabled: true,
            virtualToken: VIRTUAL_TOKEN,
            virtualQuote: VIRTUAL_QUOTE,
            curveTokens: CURVE_TOKENS,
            curveFeeBps: CURVE_FEE_BPS
        });
    }
}
