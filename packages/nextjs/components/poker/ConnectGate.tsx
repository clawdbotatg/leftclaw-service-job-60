"use client";

import { base } from "viem/chains";
import { useAccount, useSwitchChain } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";

type Props = {
  children: React.ReactNode;
};

export const ConnectGate = ({ children }: Props) => {
  const { address, chain } = useAccount();
  const { switchChain, isPending: switching } = useSwitchChain();

  if (!address) {
    return (
      <div className="card bg-base-100 shadow-xl max-w-md mx-auto my-10">
        <div className="card-body items-center text-center">
          <h2 className="card-title">Connect your wallet to play</h2>
          <p className="text-sm opacity-70">You&apos;ll need CLAWD and a little ETH for gas on Base.</p>
          <div className="card-actions mt-2">
            <RainbowKitCustomConnectButton />
          </div>
        </div>
      </div>
    );
  }

  if (chain && chain.id !== base.id) {
    return (
      <div className="card bg-base-100 shadow-xl max-w-md mx-auto my-10">
        <div className="card-body items-center text-center">
          <h2 className="card-title">Wrong network</h2>
          <p className="text-sm opacity-70">ClawdPoker lives on Base mainnet. Switch your wallet to continue.</p>
          <div className="card-actions mt-2">
            <button className="btn btn-primary" disabled={switching} onClick={() => switchChain({ chainId: base.id })}>
              {switching ? "Switching..." : "Switch to Base"}
            </button>
          </div>
        </div>
      </div>
    );
  }

  return <>{children}</>;
};
