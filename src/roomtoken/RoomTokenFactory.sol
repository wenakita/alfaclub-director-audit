// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Audit extract: only the types `AlfaClubDirector` imports from this path.
/// The full RoomToken factory / custom RoomToken path is out of scope.

struct LaunchConfig {
    uint96 launchFeeQuote;
    uint16 creatorBps;
    uint16 roomFundBps;
    uint16 platformBps;
    int24 initTick;
    uint32 capWindowSecs;
    uint16 walletCapBps;
    uint16 devBuyCapBps;
    uint32 minCountdownSecs;
    uint32 maxCountdownSecs;
    uint16 cardinalityTarget;
    uint32 twapWindowSecs;
    uint16 maxConversionDeviationBps;
    uint16 maxConversionImpactBps;
}

interface IRegistryRecipients {
    function recipientsOf(uint256 roomId) external view returns (address roomFund, address platform);
    function ensureRoomFund(uint256 roomId, address recipient) external;
}
