# AlfaClubDirector — audit scope

Public source for a [One Dollar Audit](https://onedollaraudit.com/) of `AlfaClubDirector`.

This is the official UERC20 + Uniswap V3 launch path only. It is **not** the full Friend.space / Alfa Club repo.

## In scope

| File | Why |
| --- | --- |
| [`src/director/AlfaClubDirector.sol`](src/director/AlfaClubDirector.sol) | Subject. Two-phase `launch` / `open` / `recoverUnopened`. |
| [`src/director/IOfficialUERC20Factory.sol`](src/director/IOfficialUERC20Factory.sol) | Official Uniswap factory surface used at mint. |
| [`src/director/UERC20Metadata.sol`](src/director/UERC20Metadata.sol) | Logo / metadata layout passed into `createToken`. |
| [`src/roomtoken/RoomFeeSplitter.sol`](src/roomtoken/RoomFeeSplitter.sol) | Deployed by `open()`. Locks the V3 LP NFT. |
| [`src/roomtoken/RoomRecipientRegistry.sol`](src/roomtoken/RoomRecipientRegistry.sol) | `ensureRoomFund` / `recipientsOf` during launch. |
| [`src/roomtoken/RoomTokenFactory.sol`](src/roomtoken/RoomTokenFactory.sol) | **Types only** (`LaunchConfig`, `IRegistryRecipients`) so Director imports stay unchanged. Not the old factory. |
| `src/roomtoken/interfaces/*` | Minimal Uniswap V3 NPM / router / pool surfaces. |
| `src/roomtoken/libraries/TickMath.sol` | Vendored Uniswap TickMath. |

OpenZeppelin (`Ownable`, `EIP712`, `SafeERC20`, …) is not vendored here.

## Out of scope

- Custom `RoomToken` and the full `RoomTokenFactory` launch path
- Deploy scripts, tests, keys, app / backend

## Deployed (Robinhood Chain, throwaway EOA — not vanity)

`AlfaClubDirector`: [`0x3dadFD2047C227Fe95d9895Ab30566957bc9c159`](https://robinhoodchain.blockscout.com/address/0x3dadFD2047C227Fe95d9895Ab30566957bc9c159)

Please start at `AlfaClubDirector.sol`. Focus: authority signature / economics hash, two-phase inventory custody, empty-pool reserve at `initTick`, `open` reentrancy and LP lock, `recoverUnopened` burn (tokens never returned to creator), permit pull, and `devBuy` cap math.
