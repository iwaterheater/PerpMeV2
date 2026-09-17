// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
//   perpme.fun — token launchpad on HyperEVM
//   https://perpme.fun   ·   https://x.com/perpmefun
// =============================================================================

import {Vm} from "forge-std/Vm.sol";

/**
 * @title ForkPin
 * @notice One place every fork test opens its fork through.
 *
 *         The tax suites each called `vm.createSelectFork` on the public
 *         HyperEVM RPC at whatever the latest block happened to be. Two things
 *         followed from that, and both cost real hours:
 *
 *         Every run fetched state fresh from a public endpoint, so running
 *         more than one suite at a time — which is what `forge test` does
 *         without `-j 1`, and what anyone comparing two suites does by hand —
 *         earned `-32005 rate limited` and a red suite with no revert in it.
 *         Four separate runs of this repository's suites died that way in one
 *         day, and each looked like a failing test until the trace was read.
 *
 *         And a suite that asserts amounts out of third-party pools against
 *         "latest" is asserting against a number a stranger can move. A test
 *         that goes red because somebody swapped is not reporting anything
 *         about this code.
 *
 *         So: one RPC and one block, both overridable in one place.
 *
 *         WHY THE DEFAULT BLOCK IS THE HEAD
 *
 *         Because `rpc.hyperliquid.xyz` is not an archive node, and does not
 *         say so. A historical `eth_call` against it silently answers with
 *         CURRENT state: the RAM/WHYPE pair reports the same reserves at block
 *         45,000,000 as at the head, six hundred thousand blocks later. Forge
 *         takes the header from the pinned block and the storage from that
 *         answer, so a fork pinned into the past gets a past timestamp beside
 *         present-day storage — and any contract that subtracts one from the
 *         other underflows. A Solidly pair does exactly that on every swap
 *         (`block.timestamp - blockTimestampLast`), so pinning to a block six
 *         hours old made every trade through the RAM bridge panic with 0x11,
 *         in code that is perfectly correct at the head.
 *
 *         So `FORK_BLOCK` is honoured and is worth setting — against an
 *         ARCHIVE endpoint, or against a local `anvil --fork-url … 
 *         --fork-block-number N`, which pins header and storage together and
 *         costs the public RPC nothing per run. Point `HYPEREVM_RPC_URL` at
 *         that anvil and the suites stop competing for the public endpoint's
 *         rate limit, which is what made four separate runs red in one day.
 *         Unset, the head is the only self-consistent choice this RPC offers.
 *
 * @dev A library rather than a base contract because the suites already
 *      inherit `Test` and several of them fork inside individual tests rather
 *      than in `setUp`.
 */
library ForkPin {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev 0 means the chain head — see the note above on why that is the
    ///      default rather than a number.
    uint256 internal constant DEFAULT_BLOCK = 0;

    function rpc() internal view returns (string memory) {
        return VM.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm"));
    }

    /// @notice Fork HyperEVM at the pinned block, or at the head if asked.
    function select() internal returns (uint256 forkId) {
        uint256 pinned = VM.envOr("FORK_BLOCK", DEFAULT_BLOCK);
        if (pinned == 0) return VM.createSelectFork(rpc());
        return VM.createSelectFork(rpc(), pinned);
    }
}
