"use client";

import { useCallback, useState } from "react";
import { useAccount } from "wagmi";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { parsePokerError } from "~~/utils/parseError";

type ApprovalState = {
  allowance: bigint;
  hasEnough: (amount: bigint) => boolean;
  approve: (amount: bigint) => Promise<boolean>;
  isApproving: boolean;
  approveCooldown: boolean;
  error: string | null;
  clearError: () => void;
  pokerAddress?: string;
  refetch: () => Promise<unknown>;
};

export const useClawdApproval = (): ApprovalState => {
  const { address: user } = useAccount();
  const { data: pokerInfo } = useDeployedContractInfo({ contractName: "ClawdPoker" });
  const pokerAddress = pokerInfo?.address;

  const { data: allowance, refetch } = useScaffoldReadContract({
    contractName: "CLAWD",
    functionName: "allowance",
    args: [user, pokerAddress],
    watch: true,
  });

  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "CLAWD" });

  const [submitting, setSubmitting] = useState(false);
  const [approveCooldown, setApproveCooldown] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isApproving = isPending || submitting;

  const hasEnough = useCallback(
    (amount: bigint) => {
      return ((allowance as bigint | undefined) ?? 0n) >= amount;
    },
    [allowance],
  );

  const approve = useCallback(
    async (amount: bigint): Promise<boolean> => {
      if (!pokerAddress) {
        setError("Contract address not loaded yet.");
        return false;
      }
      setSubmitting(true);
      setError(null);
      try {
        await writeContractAsync({
          functionName: "approve",
          args: [pokerAddress, amount],
        });
        setApproveCooldown(true);
        setTimeout(async () => {
          await refetch();
          setApproveCooldown(false);
        }, 4000);
        return true;
      } catch (err) {
        setError(parsePokerError(err));
        return false;
      } finally {
        setSubmitting(false);
      }
    },
    [pokerAddress, writeContractAsync, refetch],
  );

  return {
    allowance: (allowance as bigint | undefined) ?? 0n,
    hasEnough,
    approve,
    isApproving,
    approveCooldown,
    error,
    clearError: () => setError(null),
    pokerAddress,
    refetch,
  };
};
