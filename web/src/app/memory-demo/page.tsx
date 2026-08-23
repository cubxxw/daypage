import type { Metadata } from "next";
import { DecisionMemoryDemo } from "./DecisionMemoryDemo";

export const metadata: Metadata = {
  title: "决策记忆演示",
  description:
    "体验 DayPage 如何把分散的原始记录编译成可核验、可纠错、能在关键时刻重新调用的决策记忆。",
  robots: {
    index: false,
    follow: false,
  },
};

export default function MemoryDemoPage() {
  return <DecisionMemoryDemo />;
}
