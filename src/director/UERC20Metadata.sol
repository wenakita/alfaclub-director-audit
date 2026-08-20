// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Official Uniswap UERC20 metadata layout.
/// Event ABI: `TokenCreated(address,(string,string,string,bytes))`
/// topic0 `0x4ef8284ecf42d4cd19686572ffd87f630858c82398911e776cb831de35eddbf4`.
struct UERC20Metadata {
    string description;
    string website;
    string image;
    bytes extraData;
}
