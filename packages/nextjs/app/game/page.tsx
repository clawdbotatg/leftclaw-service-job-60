import { GameClient } from "./GameClient";
import type { NextPage } from "next";

// Static export on IPFS: one /game/ shell. Game id is resolved client-side
// from the ?id=<n> query string via useSearchParams. No dynamic segment
// means no pre-generation per id — every game URL routes to this shell.
const GamePage: NextPage = () => {
  return <GameClient />;
};

export default GamePage;
