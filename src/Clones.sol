// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice EIP‑1167 minimal proxy library.
/// @dev    Uses the well-proven technique of grafting the implementation
///         address into a pre-computed bytecode template.
library Clones {
    /// @dev Deploys and returns the address of a minimal proxy that
    ///      delegates all calls to `implementation`.
    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)

            // ── init code (10 bytes) + runtime prefix (9 bytes) + PUSH20 ──
            mstore(
                ptr,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )

            // ── 20‑byte implementation address ──
            // Shift left by 96 bits so the address sits at bytes 20‑39 of
            // the deployment code (right after PUSH20 at byte 19).
            mstore(add(ptr, 0x14), shl(0x60, implementation))

            // ── DELEGATECALL return‑data forwarding suffix ──
            mstore(
                add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )

            // Deploy 55 bytes (0x37) starting at `ptr`.
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "clone failed");
    }
}