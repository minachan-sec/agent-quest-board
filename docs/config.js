// Agent Quest Board — shared configuration.
// The contract address is the deterministic CREATE2 address for salt
// keccak256("agent-quest-board-v1.1") through the canonical factory
// (0x4e59b44847b379578588920cA78FbF26c0B4956C). The app checks on load
// whether code exists at this address: before deployment it shows a
// "not deployed yet" banner and the board stays empty; after deployment
// everything lights up with no code change.
window.QBCFG = {
  contractAddress: "0x7f41A272D523b99e644B6362dABB852FF16316A8",
  chainId: 56,
  chainName: "BNB Smart Chain",
  registryAddress: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",
  factoryAddress: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
  bscscanBase: "https://bscscan.com",
  // Public BSC RPC endpoints, tried in order. All are read-only for us
  // (eth_call / eth_getLogs only — this site never sends transactions).
  rpcUrls: [
    "https://bsc-dataseed.binance.org/",
    "https://bsc-dataseed1.defibit.io/",
    "https://bsc-dataseed1.ninicoin.io/",
    "https://bsc-rpc.publicnode.com"
  ],
  // Contract constants (mirror of the on-chain values, for display math).
  reviewWindowSeconds: 7 * 24 * 3600,
  staleGraceSeconds: 7 * 24 * 3600,
  openLifetimeSeconds: 90 * 24 * 3600,
  resubmitWindowSeconds: 24 * 3600,
  minRewardWei: "1000000000000000", // 0.001 BNB
  pageSize: 20,
  maxInitialQuests: 100,
  // First block to scan for quest events. Set to the deploy block
  // (19 Nov 2026) to keep the event scan fast.
  deployBlock: 134458128
};
