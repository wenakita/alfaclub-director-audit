# Director — audit scope

Source for a security review of `AlfaClubDirector` and the contracts it deploys or calls.

This repo is the official UERC20 + Uniswap V3 launch path only. It is not a full application monorepo.

## In scope

| File | Why |
| --- | --- |
| [`src/director/AlfaClubDirector.sol`](src/director/AlfaClubDirector.sol) | Subject. Two-phase `launch` / `open` / `recoverUnopened`. |
| [`src/director/IOfficialUERC20Factory.sol`](src/director/IOfficialUERC20Factory.sol) | Official Uniswap factory surface used at mint. |
| [`src/director/UERC20Metadata.sol`](src/director/UERC20Metadata.sol) | Logo / metadata layout passed into `createToken`. |
| [`src/roomtoken/RoomFeeSplitter.sol`](src/roomtoken/RoomFeeSplitter.sol) | Deployed by `open()`. Locks the V3 LP NFT. |
| [`src/roomtoken/RoomRecipientRegistry.sol`](src/roomtoken/RoomRecipientRegistry.sol) | `ensureRoomFund` / `recipientsOf` during launch. |
| [`src/roomtoken/RoomTokenFactory.sol`](src/roomtoken/RoomTokenFactory.sol) | **Types only** (`LaunchConfig`, `IRegistryRecipients`) so Director imports stay unchanged. Not a factory implementation. |
| `src/roomtoken/interfaces/*` | Minimal Uniswap V3 NPM / router / pool surfaces. |
| `src/roomtoken/libraries/TickMath.sol` | Vendored Uniswap TickMath. |

OpenZeppelin (`Ownable`, `EIP712`, `SafeERC20`, …) is not vendored here.

## Out of scope

- Other token implementations and the unused factory launch path
- Deploy scripts, tests, and off-chain services

Start at `AlfaClubDirector.sol`. Suggested focus: authority signature / economics hash, two-phase inventory custody, empty-pool reserve at `initTick`, `open` reentrancy and LP lock, `recoverUnopened` burn (tokens never returned to the creator), permit pull, and `devBuy` cap math.
