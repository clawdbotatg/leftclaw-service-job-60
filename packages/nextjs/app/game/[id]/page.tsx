import { GameClient } from "./GameClient";
import type { NextPage } from "next";

// Static export: emit a placeholder shell; actual game id is resolved
// client-side from the URL via useParams().
export function generateStaticParams() {
  return [{ id: "0" }];
}

const GamePage: NextPage = () => {
  return <GameClient />;
};

export default GamePage;
