// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// Resolves the custodial fee legs (room fund, platform) per room. Owned by
/// the platform Safe. The creator leg deliberately does NOT resolve here —
/// it lives in each splitter, redirectable by the creator alone.
/// Ownable2Step: a mistaken transferOwnership() cannot brick the registry —
/// the incoming owner must call acceptOwnership() before control moves.
contract RoomRecipientRegistry is Ownable2Step {
    struct Recipients {
        address roomFund;
        address platform;
    }

    mapping(uint256 roomId => Recipients) private _recipients;
    address public defaultPlatformRecipient;

    /// The RoomTokenFactory, which maps a room's fee recipient inside the
    /// launch transaction that creates its splitter. Deliberately cannot
    /// overwrite an existing mapping: a conflicting value means someone's
    /// expectation is wrong, and reverting the launch is the safe answer —
    /// the owner repairs it with setRecipients.
    address public provisioner;

    error RenounceDisabled();
    error NotProvisioner();
    error RoomFundConflict();
    error ZeroRecipient();

    event RecipientsSet(uint256 indexed roomId, address roomFund, address platform);
    event DefaultPlatformRecipientSet(address recipient);
    event ProvisionerSet(address provisioner);
    event RoomFundProvisioned(uint256 indexed roomId, address roomFund);

    constructor(address owner_, address defaultPlatformRecipient_) Ownable(owner_) {
        defaultPlatformRecipient = defaultPlatformRecipient_;
    }

    /// The registry owner is the permanent authority anchor for every
    /// splitter deployed against it (operator rotation, creator rescue).
    /// Renouncing would brick all of them irreversibly, so it is disabled —
    /// use transferOwnership (Ownable2Step) to move control instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setRecipients(uint256 roomId, address roomFund, address platform) external onlyOwner {
        _recipients[roomId] = Recipients(roomFund, platform);
        emit RecipientsSet(roomId, roomFund, platform);
    }

    function setProvisioner(address next) external onlyOwner {
        provisioner = next;
        emit ProvisionerSet(next);
    }

    /// Writes ONLY the room-fund leg; `platform` stays zero so it keeps
    /// resolving through defaultPlatformRecipient. Idempotent when the
    /// mapping already names the same recipient, so a relaunch against a
    /// fresh factory is not blocked by a mapping that is already correct.
    function ensureRoomFund(uint256 roomId, address recipient) external {
        if (msg.sender != provisioner) revert NotProvisioner();
        if (recipient == address(0)) revert ZeroRecipient();
        address current = _recipients[roomId].roomFund;
        if (current == recipient) return;
        if (current != address(0)) revert RoomFundConflict();
        _recipients[roomId].roomFund = recipient;
        emit RoomFundProvisioned(roomId, recipient);
    }

    function setDefaultPlatformRecipient(address recipient) external onlyOwner {
        defaultPlatformRecipient = recipient;
        emit DefaultPlatformRecipientSet(recipient);
    }

    function recipientsOf(uint256 roomId) external view returns (address roomFund, address platform) {
        Recipients memory r = _recipients[roomId];
        roomFund = r.roomFund;
        platform = r.platform == address(0) ? defaultPlatformRecipient : r.platform;
    }
}
