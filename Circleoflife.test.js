// tests/CircleofLife.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

describe("CircleofLife", function () {
  let CircleofLife, nft, owner, addr1, addr2, addr3;
  let merkleRoot, tree;

  beforeEach(async () => {
    [owner, addr1, addr2, addr3] = await ethers.getSigners();
    CircleofLife = await ethers.getContractFactory("CircleofLife");
    nft = await CircleofLife.deploy("Circle of Life", "COL", "ipfs://baseURI/", 10000);
    await nft.deployed();

    const whitelistAddresses = [addr1.address, addr2.address];
    const leafNodes = whitelistAddresses.map(addr => keccak256(addr));
    tree = new MerkleTree(leafNodes, keccak256, { sortPairs: true });
    merkleRoot = tree.getHexRoot();
    await nft.setMerkleRoot(merkleRoot);
    await nft.setMintPrice(ethers.utils.parseEther("0.01"));
  });

  it("should deploy with correct initial values", async () => {
    expect(await nft.name()).to.equal("Circle of Life");
    expect(await nft.symbol()).to.equal("COL");
    expect(await nft.nextId()).to.equal(1);
  });

  it("owner can mint NFTs with mintNext", async () => {
    await expect(nft.mintNext(addr1.address, 3))
      .to.emit(nft, "Transfer")
      .withArgs(ethers.constants.AddressZero, addr1.address, 1);
    expect(await nft.ownerOf(1)).to.equal(addr1.address);
  });

  it("non-owner cannot mint using mintNext", async () => {
    await expect(nft.connect(addr1).mintNext(addr1.address, 1)).to.be.reverted;
  });

  it("whitelisted address can mint with correct proof", async () => {
    const proof = tree.getHexProof(keccak256(addr1.address));
    await expect(
      nft.connect(addr1).mintWhitelist(proof, { value: ethers.utils.parseEther("0.01") })
    ).to.emit(nft, "Transfer");
    expect(await nft.ownerOf(1)).to.equal(addr1.address);
  });

  it("non-whitelisted address cannot mint", async () => {
    const proof = tree.getHexProof(keccak256(addr3.address));
    await expect(
      nft.connect(addr3).mintWhitelist(proof, { value: ethers.utils.parseEther("0.01") })
    ).to.be.revertedWith("InvalidProof");
  });

  it("prevents multiple whitelist mints from same address", async () => {
    const proof = tree.getHexProof(keccak256(addr1.address));
    await nft.connect(addr1).mintWhitelist(proof, { value: ethers.utils.parseEther("0.01") });
    await expect(
      nft.connect(addr1).mintWhitelist(proof, { value: ethers.utils.parseEther("0.01") })
    ).to.be.revertedWith("AlreadyClaimed");
  });

  it("owner can set and clear token URI", async () => {
    await nft.mintNext(owner.address, 1);
    await expect(nft.setTokenURI(1, "ipfs://customURI/1.json"))
      .to.emit(nft, "TokenURIUpdated");
    await expect(nft.clearTokenURI(1)).to.emit(nft, "MetadataUpdate");
  });

  it("sets and updates royalty info", async () => {
    await nft.setDefaultRoyalty(addr2.address, 500);
    const royaltyInfo = await nft.royaltyInfo(1, 10000);
    expect(royaltyInfo[0]).to.equal(addr2.address);
    expect(royaltyInfo[1]).to.equal(500);
  });

  it("owner can withdraw balance", async () => {
    await owner.sendTransaction({ to: nft.address, value: ethers.utils.parseEther("1") });
    const balanceBefore = await ethers.provider.getBalance(owner.address);
    const tx = await nft.withdraw(owner.address);
    const receipt = await tx.wait();
    const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);
    const balanceAfter = await ethers.provider.getBalance(owner.address);
    expect(balanceAfter).to.be.closeTo(
      balanceBefore.add(ethers.utils.parseEther("1")).sub(gasUsed),
      ethers.utils.parseEther("0.01")
    );
  });

  it("respects MAX_MINT_PER_TX limit", async () => {
    const max = await nft.MAX_MINT_PER_TX();
    await expect(nft.mintNext(addr1.address, max.add(1))).to.be.revertedWith("ExceedsPerTxLimit");
  });

  it("respects MAX_BATCH_OPS limit on batchTransfer", async () => {
    const maxBatch = await nft.MAX_BATCH_OPS();
    await nft.mintNext(owner.address, maxBatch);
    const tokenIds = Array.from({ length: maxBatch.toNumber() + 1 }, (_, i) => i + 1);
    await expect(
      nft.batchTransfer(addr1.address, tokenIds)
    ).to.be.revertedWith("ExceedsPerTxLimit");
  });

  it("pauses and unpauses contract correctly", async () => {
    await nft.pause();
    await expect(nft.mintNext(owner.address, 1)).to.be.revertedWith("Pausable: paused");
    await nft.unpause();
    await nft.mintNext(owner.address, 1);
    expect(await nft.ownerOf(1)).to.equal(owner.address);
  });

  it("supports ERC165 interface IDs", async () => {
    expect(await nft.supportsInterface("0x80ac58cd")).to.equal(true); // ERC721
    expect(await nft.supportsInterface("0x5b5e139f")).to.equal(true); // Metadata
    expect(await nft.supportsInterface("0x2a55205a")).to.equal(true); // ERC2981
  });
});
