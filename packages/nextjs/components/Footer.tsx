"use client";

import React from "react";
import Link from "next/link";
import { Address } from "@scaffold-ui/components";
import { SwitchTheme } from "~~/components/SwitchTheme";
import { useDeployedContractInfo } from "~~/hooks/scaffold-eth";

export const Footer = () => {
  const { data: poker } = useDeployedContractInfo({ contractName: "ClawdPoker" });
  const pokerAddress = poker?.address;

  return (
    <div className="min-h-0 py-5 px-1 mb-11 lg:mb-0">
      <div>
        <div className="fixed flex justify-end items-center w-full z-10 p-4 bottom-0 left-0 pointer-events-none">
          <SwitchTheme className="pointer-events-auto" />
        </div>
      </div>
      <div className="w-full">
        <ul className="menu menu-horizontal w-full">
          <div className="flex flex-col md:flex-row justify-center items-center gap-2 text-sm w-full">
            <span className="font-semibold">ClawdPoker</span>
            {pokerAddress && (
              <>
                <span className="hidden md:inline">·</span>
                <Address address={pokerAddress} format="short" />
                <span className="hidden md:inline">·</span>
                <Link
                  href={`https://basescan.org/address/${pokerAddress}`}
                  target="_blank"
                  rel="noreferrer"
                  className="link"
                >
                  Basescan
                </Link>
              </>
            )}
            <span className="hidden md:inline">·</span>
            <span className="opacity-70">Heads-up Texas Hold&apos;em on Base</span>
          </div>
        </ul>
      </div>
    </div>
  );
};
