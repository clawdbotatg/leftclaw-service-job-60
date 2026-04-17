"use client";

import { useEffect, useState } from "react";

type Props = {
  lastActionTime: bigint;
  timeoutSeconds: bigint;
};

const fmt = (secs: number): string => {
  if (secs <= 0) return "timed out";
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
};

export const CountdownTimer = ({ lastActionTime, timeoutSeconds }: Props) => {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const i = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(i);
  }, []);

  const deadline = Number(lastActionTime) + Number(timeoutSeconds);
  const remaining = deadline - now;
  const timedOut = remaining <= 0;

  return (
    <span className={`font-mono text-xs ${timedOut ? "text-error" : "opacity-60"}`}>
      {timedOut ? "timeout elapsed" : `${fmt(remaining)} until timeout`}
    </span>
  );
};

export const hasTimedOut = (lastActionTime: bigint, timeoutSeconds: bigint): boolean => {
  const deadline = Number(lastActionTime) + Number(timeoutSeconds);
  return Math.floor(Date.now() / 1000) > deadline;
};
