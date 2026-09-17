// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PerpMeTaxToken} from "./PerpMeTaxToken.sol";

/**
 * @title PerpMeTaxTokenDeployer
 * @notice Deploys one whole dividend coin per launch, with CREATE2.
 *
 *         Its own contract for the same boring reason the V3 one is: EIP-170
 *         caps a contract's runtime at 24,576 bytes, and a coin's creation code
 *         alone is over fifteen thousand. Embedding it in the factory would
 *         leave no room for the factory, and the failure would arrive at
 *         deployment time rather than compile time.
 *
 *         Deployment and initialization stay separate. This contract only
 *         deploys; the FACTORY calls `initialize`, so the coin records the
 *         factory as its factory rather than this helper. Both happen in one
 *         transaction, so there is no moment at which an uninitialized coin is
 *         reachable — and in any case only the factory may call `deploy`.
 */
contract PerpMeTaxTokenDeployer {
    /// @dev The one caller allowed, passed in as a predicted address.
    address public immutable FACTORY;

    error NotFactory();

    constructor(address factory_) {
        FACTORY = factory_;
    }

    /// @notice Deploy an uninitialized coin at a deterministic address.
    function deploy(bytes32 salt) external returns (address token) {
        if (msg.sender != FACTORY) revert NotFactory();
        token = address(new PerpMeTaxToken{salt: salt}());
    }

    /// @notice The address `deploy` would produce for this salt.
    function predict(bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, INIT_CODE_HASH))
                )
            )
        );
    }

    /**
     * @dev Published so the create page mines against the same number the chain
     *      will use. Constant across coins because the coin's constructor takes
     *      no arguments — which is what lets the browser hash 32 bytes per
     *      attempt instead of fifteen kilobytes.
     */
    bytes32 public constant INIT_CODE_HASH = keccak256(type(PerpMeTaxToken).creationCode);
}
