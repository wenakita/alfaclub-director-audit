// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UERC20Metadata} from "./UERC20Metadata.sol";

/// Official Uniswap `UERC20Factory` surface used by AlfaClubDirector.
interface IOfficialUERC20Factory {
    event TokenCreated(address tokenAddress, UERC20Metadata metadata);

    error RecipientCannotBeZeroAddress();
    error TotalSupplyCannotBeZero();

    function createToken(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 initialSupply,
        address recipient,
        bytes calldata data,
        bytes32 graffiti
    ) external returns (address tokenAddress);

    function getUERC20Address(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address creator,
        bytes32 graffiti
    ) external view returns (address);
}

/// Official UERC20 getters AlfaClubDirector / tests read after `createToken`.
interface IOfficialUERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function creator() external view returns (address);
    function graffiti() external view returns (bytes32);
    function metadata() external view returns (string memory, string memory, string memory, bytes memory);
    function tokenURI() external view returns (string memory);
}
