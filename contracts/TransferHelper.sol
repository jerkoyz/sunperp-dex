// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.2.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";

/// @title TransferHelper
/// @notice Contains helper methods for interacting with ERC20 tokens that do not consistently return true/false
library TransferHelper {
    // address constant USDTAddr = 0xECa9bC828A3005B9a3b909f2cc5c2a54794DE05F;
    address constant USDTAddr = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C; // miannet USDT address
    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Calls transfer on token contract, errors with TF if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
                            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if(token == USDTAddr){
            data = "";
        }
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TF');
    }
}