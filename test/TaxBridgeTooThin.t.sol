// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpMeBridge} from "../src/tax/PerpMeBridge.sol";

contract BridgeHarness is PerpMeBridge {
    constructor(address r, address w) PerpMeBridge(r, w) {}
    receive() external payable {}

    function hypeToQuote(bytes calldata bridge, address quote, uint256 hype) external payable returns (uint256 out) {
        (out,) = _hypeToQuote(bridge, quote, hype, 0);
    }

    function quoteToWrapped(bytes calldata bridge, address quote, uint256 amount) external returns (uint256) {
        return _quoteToWrapped(bridge, quote, amount);
    }
}

/**
 * A V3 bridge too thin for the amount fails the trade instead of leaving the
 * rest in PRJX's router for anyone to take.
 *
 * Found on a mainnet fork 2026-09-15 while measuring what graduating each
 * shipped pair costs: wSPYx's pool against WHYPE delivers about 8.5 wSPYx in
 * total, so 500 HYPE bought that and stranded 414 HYPE in the router, where a
 * stranger's `refundETH()` collected it.
 */
contract TaxBridgeTooThinTest is Test {
    address constant SWAP_ROUTER = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant JOFF = 0x62D5dD0190376c444a4B2E2e860aa392eC83Ed80;

    BridgeHarness bridge;

    function setUp() public {
        vm.createSelectFork(vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm")));
        bridge = new BridgeHarness(SWAP_ROUTER, WHYPE);
    }

    function _in(address q, uint24 fee) internal pure returns (bytes memory) {
        return abi.encodePacked(WHYPE, fee, q);
    }

    function test_AnOrdinaryBuyStillGoesThrough() public {
        uint256 out = bridge.hypeToQuote{value: 2 ether}(_in(WSPYX, 10000), WSPYX, 2 ether);
        assertGt(out, 0);
        assertEq(IERC20(WSPYX).balanceOf(address(bridge)), out);
    }

    function test_ABuyLargerThanThePoolReverts() public {
        uint256 routerBefore = SWAP_ROUTER.balance;
        vm.expectRevert(PerpMeBridge.BridgeTooThin.selector);
        bridge.hypeToQuote{value: 500 ether}(_in(WSPYX, 10000), WSPYX, 500 ether);
        assertEq(SWAP_ROUTER.balance, routerBefore, "nothing left in PRJX's router");
    }

    /// Two hops: the first pool can take it all, the second cannot, and the
    /// USDC between them would have been the stranded part.
    function test_ATwoHopBuyThatRunsOutInTheMiddleReverts() public {
        bytes memory path = abi.encodePacked(WHYPE, uint24(500), USDC, uint24(10000), JOFF);
        uint256 usdcBefore = IERC20(USDC).balanceOf(SWAP_ROUTER);
        vm.expectRevert(PerpMeBridge.BridgeTooThin.selector);
        bridge.hypeToQuote{value: 1000 ether}(path, JOFF, 1000 ether);
        assertEq(IERC20(USDC).balanceOf(SWAP_ROUTER), usdcBefore);
    }

    function test_ASaleLargerThanThePoolReverts() public {
        deal(WSPYX, address(bridge), 1_000e18);
        vm.expectRevert(PerpMeBridge.BridgeTooThin.selector);
        bridge.quoteToWrapped(abi.encodePacked(WSPYX, uint24(10000), WHYPE), WSPYX, 1_000e18);
    }

    function test_AnOrdinarySaleStillGoesThrough() public {
        deal(WSPYX, address(bridge), 0.1e18);
        uint256 wrapped = bridge.quoteToWrapped(abi.encodePacked(WSPYX, uint24(10000), WHYPE), WSPYX, 0.1e18);
        assertGt(wrapped, 0);
        assertEq(IERC20(WSPYX).balanceOf(address(bridge)), 0);
    }
}
