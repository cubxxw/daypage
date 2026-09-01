import type { ProposedAction } from "@/lib/agent-data-plane/contracts";

const CONFIRMATION_TOOL = /^(?:calendar\.create_|email\.(?:create_|send)|publish\.|web\.upload)|(?:^|\.)(?:delete|destroy|purge)$/i;

export function actionRequiresConfirmation(action: ProposedAction): boolean {
  return (
    action.effect === "external_write" ||
    action.effect === "destructive" ||
    CONFIRMATION_TOOL.test(action.tool)
  );
}
