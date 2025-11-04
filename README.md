# **CIRCLE OF LIFE**
### An ERC‑721 project, designed for the NFT *Circle of Life* by artist Jack S. Santosi. 
- col.sol – lean sales / airdrop wrapper over MyNFT (recommended for standard drops).
- COLPresentation.sol (optional) – 1/1 presentation NFT: on‑chain JSON metadata with image (poster) and animation_url (PDF/MP4/HTML), plus a SHA‑256 integrity hash of the document.

---

## Standards Implemented

- **ERC-165** — interface discovery.
- **ERC-721** — core NFT.
- **ERC-721 Metadata** — `name`, `symbol`, `tokenURI`.
- **ERC-721 Enumerable** — owner/global index helpers (with known gas trade-offs).
- **ERC-4906** — metadata update events so marketplaces refresh on URI changes.
- **ERC-2981** — royalties (default global rate; optional per-token overrides in the core).

**Optional**
- **Operator Filtering** — registry-based operator checks for marketplaces that enforce royalty-compliant operators.

---


## Testing


This project includes a full test suite built with **Hardhat**, **Waffle**, and **Chai**.


### Run Tests:
```bash
npx hardhat test
```


### Run Coverage:
```bash
npx hardhat coverage
```


### Sample Output:
```
CircleofLife
✓ should deploy with correct initial values
✓ owner can mint NFTs with mintNext
✓ non-owner cannot mint using mintNext
✓ whitelisted address can mint with correct proof
✓ non-whitelisted address cannot mint
✓ prevents multiple whitelist mints from same address
✓ owner can set and clear token URI
✓ sets and updates royalty info
✓ owner can withdraw balance
✓ respects MAX_MINT_PER_TX limit
✓ respects MAX_BATCH_OPS limit on batchTransfer
✓ pauses and unpauses contract correctly
✓ supports ERC165 interface IDs


13 passing (X seconds)
```


Test coverage includes:
- Contract deployment
- Whitelist minting (Merkle Proof)
- Paid and free minting paths
- URI management
- Royalty configuration
- Batch transfer safeguards
- Pausability
- Interface detection (ERC165)
- Event emission checks


---

## Contract Set

### 1) `Collection-Minting-Transfer.sol` (Core)
Your custom, hardened ERC-721 implementation:

- **Controls & State**
    - `pause/unpause` gates for transfers/mints/burns.
    - `maxSupply` guard; adjustable upward via `setMaxSupply` (never below current `totalSupply()`).
    - **Monotonic auto-IDs** via `nextId` (owner mints: `mintNext`, `safeMintNext`).
    - `setBaseURI` + **per-token URI override** via `setTokenURI`.
    - UX helpers: `tokensOfOwner(address)`, `totalSupply()`, `totalBurned()`.

- **Minting**
    - Owner: `mintNext(to, amount)`, `safeMintNext(to, amount)`, `batchMint(...)`.
    - Public: `publicMint(tokenId, proof)` with **mint price** + **Merkle whitelist** (refunds any excess).

- **Royalties (ERC-2981)**
    - Global default via `setDefaultRoyalty(receiver, bps)`.
    - Optional **per-token** royalty mappings.

- **Operator Filtering (optional)**
    - `setOperatorFilterRegistry(registry, enabled)`.
    - Enforcement on approvals/transfers with `onlyAllowedOperator*` modifiers.

- **Withdrawals**
    - `withdraw(address payable)` with reentrancy protection.

- **Security Choices**
    - **Reentrancy guards only where needed** (public mint/withdraw/large loops), removed from owner-only single-step flows.
    - Batch functions exist but **wrappers cap per-tx counts** to avoid block gas blowups.

- **Interfaces Exposed**
    - ERC-165 reports: **IERC165**, **IERC721**, **IERC721Metadata**, **(optional) IERC721Enumerable**, **ERC-4906**, **ERC-2981**.

---

### 2) `col.sol` (Unified Sales & Presentation Wrapper)
Thin project-level layer over the core:

- **Admin shortcuts**
    - `openSale(price, merkleRoot)` → set mint price & whitelist and `unpause`.
    - `closeSale()`, `configureRoyalty(receiver, bps)`.

- **Distribution utilities**
    - `teamMint(amount)` (capped per tx).
    - `airdrop(recipients, amounts)` (capped).
    - `airdrop1(recipients)` (1 per recipient, capped).

- **Presentation mint**
    - `mintPresentation1of1(to, name, desc, posterURI, mediaURI, externalURL)`  
      Mints exactly **one** token using core's `nextId`, and writes **on-chain base64 JSON** with:
        - `image` (poster/thumbnail),
        - `animation_url` (PDF/MP4/HTML),
        - `doc_sha256` + `doc_mime` for integrity.

- **Safety caps**
    - `MAX_MINT_PER_TX` and `MAX_BATCH_OPS` to avoid block gas explosions.

- **ERC-165**
    - Wrapper `supportsInterface` delegates cleanly to the core.

---

---

## Media & Metadata Model

- Poster (e.g., `cover.png`) → **`image`**.
- Presentation (`slides.pdf` OR `video.mp4` OR `index.html`) → **`animation_url`**.
- **Integrity** — compute SHA-256 of the presentation and store as `doc_sha256`.
- For the 1/1 flow, metadata is stored **on-chain** as `data:application/json;base64,...` via `setTokenURI`.

**Recommended storage:** `ipfs://<CID>/cover.png`, `ipfs://<CID>/slides.pdf`  
(HTTPS works, but IPFS offers content addressability.)

---

## Requirements

- Node.js ≥ 18, NPM or PNPM.
- One of: **Hardhat** or **Foundry**.
- RPC endpoint (e.g., Infura/Alchemy) & funded deployer key.

---

## Setup
```bash
# Hardhat
npm i --save-dev hardhat @nomicfoundation/hardhat-toolbox ethers dotenv
# or use Foundry (forge)
````
---
# Hardhat config example (hardhat.config.ts):
```bash
ts

import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv"; dotenv.config();

const config: HardhatUserConfig = {
  solidity: "0.8.26",
  networks: {
    sepolia: { url: process.env.RPC_URL_SEPOLIA!, accounts: [process.env.PRIVATE_KEY!] }
  }
};
export default config;
```
---

# .env example:
```bash
RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/your-project-id"
PRIVATE_KEY="0xyourprivatekey"
```

---


```bash
npx hardhat compile
npx hardhat run scripts/deploy-col.ts --network sepolia

````

---


```bash
forge script script/DeployCOL.s.sol --rpc-url $RPC_URL_SEPOLIA --private-key $PRIVATE_KEY --broadcast
````
___

# Minting Flows

## Owner / Team

- `mintNext(to, amount)` / `safeMintNext(to, amount)` — monotonic IDs.
- `teamMint(amount)` (wrapper) — capped per tx.
- `airdrop(recipients, amounts)` / `airdrop1(recipients)` — capped distribution helpers.

## Public (Whitelist)

1. Build a Merkle tree from the allowlist of addresses.
2. `openSale(price, merkleRoot)` to set price + whitelist and unpause.
3. Users call `publicMint(tokenId, proof)` with exact payment; the core verifies the proof and refunds any excess.
4. Build proofs off-chain (e.g., `merkletreejs`), keep only the root + proofs on-chain.

# Presentation 1/1

---

# IPFS Guide

- Pin assets with a pinning service (Pinata, web3.storage, Infura IPFS, etc.) or your own node.
- Prefer a folder structure: `ipfs://<CID>/cover.png`, `ipfs://<CID>/slides.pdf`.
- IPFS is content-addressed. Changing a file → new CID. Update token URI if assets change.
- For persistence, pin redundantly and consider Filecoin/Arweave mirrors.

---

# Royalties

- Set via `configureRoyalty(receiver, bps)` (wrapper) or core constructor/setter.
- Uses **ERC-2981**; marketplaces that support it will respect the returned royalty info.
- Per-token override is available at the core level if/when required.

---

# Operator Filtering (toggleable)

If a marketplace requires operator filtering, set a valid registry address during deploy or via the core/wrapper setter:

```solidity
setOperatorFilterRegistry(registry, enabled);
```
Leave as address(0) (or enabled = false) to disable in private ecosystems.
The core enforces checks on `setApprovalForAll`, `approve`, and transfer functions with the `onlyAllowedOperator` and `onlyAllowedOperatorApproval` modifiers.
---
| Setting         | Where                        | Notes                                      |
| --------------- | ---------------------------- | ------------------------------------------ |
| `maxSupply`     | constructor / `setMaxSupply` | Hard cap; cannot mint beyond it            |
| `mintPrice`     | `openSale` / setter          | Price used in `publicMint`                 |
| `merkleRoot`    | `openSale` / setter          | Whitelist root from off-chain tree         |
| `pause/unpause` | admin                        | Halts transfers/mints/burns when paused    |
| `nextId`        | core                         | Monotonic auto-increment for token IDs     |
| `setBaseURI`    | admin                        | Only relevant for off-chain URIs           |
| `setTokenURI`   | admin                        | Used for on-chain JSON in 1/1 presentation |
| Caps (wrapper)  | constants                    | `MAX_MINT_PER_TX`, `MAX_BATCH_OPS`         |

---

# Security & Gas Notes

- **No giant batches:** wrapper enforces conservative caps to avoid block gas exhaustion.
- **Enumerable** included for UX; gas cost acknowledged (OK for small/medium editions).
- **Reentrancy guards** placed only where needed (refunds/withdraw/loops).
- **Operator Filtering** optional; disable where not needed.
- **Integrity first:** record `doc_sha256` & `doc_mime` in metadata for buyer trust.

---

# Troubleshooting

- **MaxSupplyReached** → Hit the cap; increase via `setMaxSupply` only if allowed by your policy, or redeploy.
- **InvalidProof** on `publicMint` → Address not in allowlist or tree mismatch; rebuild the Merkle tree and proofs.
- **NotAuthorized** on approvals/transfers → Not owner/approved or operator filter rejects the operator.
- **Presentation not visible** → Ensure `animation_url` is reachable (`ipfs://` preferred) and allow time for ERC-4906 refresh.

---
## Developer Credits

This project was developed by me (Konrad Erwerle) as part of a freelance engagement for artist Jack S. Santosi.  
The code reflects my implementation work, including architecture, security, and feature integration.  
Ownership and licensing rights remain with the client under MIT © Jack S. Santosi, Konrad Erwerle.

