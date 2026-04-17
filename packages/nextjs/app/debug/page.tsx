import { DebugContracts } from "./_components/DebugContracts";
import type { NextPage } from "next";
import { getMetadata } from "~~/utils/scaffold-eth/getMetadata";

export const metadata = getMetadata({
  title: "Debug ClawdPoker",
  description: "Inspect on-chain state of the ClawdPoker contract on Base.",
});

const Debug: NextPage = () => {
  return (
    <>
      <DebugContracts />
      <div className="text-center mt-8 bg-secondary p-10">
        <h1 className="text-4xl my-0">Debug ClawdPoker</h1>
        <p className="text-neutral">
          Read and write against the deployed ClawdPoker contract directly. Use the lobby for normal play.
        </p>
      </div>
    </>
  );
};

export default Debug;
