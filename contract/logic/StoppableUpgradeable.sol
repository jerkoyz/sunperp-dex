// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ContextUpgradeable} from "./ContextUpgradeable.sol";
import {Initializable} from "./Initializable.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotStopped` and `whenStopped`, which can be applied to
 * the functions of your contract. Note that they will not be stoppable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract StoppableUpgradeable is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.Stoppable
    struct StoppableStorage {
        bool _stopped;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Stoppable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StoppableStorageLocation = 0x0945f4ae23d732b4b7606be6473bb50d58246950542e3b5e6223b1c9336b1700;

    function _getStoppableStorage() private pure returns (StoppableStorage storage $) {
        assembly {
            $.slot := StoppableStorageLocation
        }
    }

    /**
     * @dev Emitted when the stop is triggered by `account`.
     */
    event Stopped(address account);

    /**
     * @dev Emitted when the stop is lifted by `account`.
     */
    event Unstopped(address account);

    /**
     * @dev The operation failed because the contract is stopped.
     */
    error EnforcedStop();

    /**
     * @dev The operation failed because the contract is not stopped.
     */
    error ExpectedStop();

    /**
     * @dev Initializes the contract in unstopped state.
     */
    function __Stoppable_init() internal onlyInitializing {
        __Stoppable_init_unchained();
    }

    function __Stoppable_init_unchained() internal onlyInitializing {
        StoppableStorage storage $ = _getStoppableStorage();
        $._stopped = false;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not stopped.
     *
     * Requirements:
     *
     * - The contract must not be stopped.
     */
    modifier whenNotStopped() {
        _requireNotStopped();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is stopped.
     *
     * Requirements:
     *
     * - The contract must be stopped.
     */
    modifier whenStopped() {
        _requireStopped();
        _;
    }

    /**
     * @dev Returns true if the contract is stopped, and false otherwise.
     */
    function stopped() public view virtual returns (bool) {
        StoppableStorage storage $ = _getStoppableStorage();
        return $._stopped;
    }

    /**
     * @dev Throws if the contract is stopped.
     */
    function _requireNotStopped() internal view virtual {
        if (stopped()) {
            revert EnforcedStop();
        }
    }

    /**
     * @dev Throws if the contract is not stopped.
     */
    function _requireStopped() internal view virtual {
        if (!stopped()) {
            revert ExpectedStop();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be stopped.
     */
    function _stop() internal virtual whenNotStopped {
        StoppableStorage storage $ = _getStoppableStorage();
        $._stopped = true;
        emit Stopped(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be stopped.
     */
    function _unstop() internal virtual whenStopped {
        StoppableStorage storage $ = _getStoppableStorage();
        $._stopped = false;
        emit Unstopped(_msgSender());
    }
}