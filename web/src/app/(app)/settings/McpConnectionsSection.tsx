"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Bot, Copy, ExternalLink, ShieldCheck, Trash2 } from "lucide-react";
import { Btn, Card, Chip, SectionLabel } from "@/components/ui";

interface McpConnection {
  client: { id: string; name: string; uri: string; logo_uri: string };
  scopes: string[];
  granted_at: string;
  can_read: boolean;
  can_write: boolean;
  daypage_grant_active: boolean;
}

interface McpConnectionsResponse {
  connections: McpConnection[];
  mcp_url: string | null;
}

function useConnections() {
  return useQuery<McpConnectionsResponse>({
    queryKey: ["mcp-connections"],
    queryFn: async () => {
      const response = await fetch("/api/oauth/grants");
      if (!response.ok) throw new Error("Failed to load connected apps");
      return response.json() as Promise<McpConnectionsResponse>;
    },
  });
}

export function McpConnectionsSection() {
  const queryClient = useQueryClient();
  const { data, isLoading, error } = useConnections();
  const revoke = useMutation({
    mutationFn: async (clientId: string) => {
      const response = await fetch("/api/oauth/grants", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_id: clientId }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({})) as { error?: string };
        throw new Error(body.error ?? "Failed to revoke connection");
      }
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mcp-connections"] }),
  });
  const updateWrite = useMutation({
    mutationFn: async ({ clientId, canWrite }: { clientId: string; canWrite: boolean }) => {
      const response = await fetch("/api/oauth/grants", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_id: clientId, can_write: canWrite }),
      });
      if (!response.ok) throw new Error("Failed to update permission");
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mcp-connections"] }),
  });

  async function copyEndpoint() {
    if (data?.mcp_url) await navigator.clipboard.writeText(data.mcp_url).catch(() => undefined);
  }

  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={data?.mcp_url ? (
          <Btn kind="soft" size="sm" onClick={copyEndpoint} icon={<Copy size={14} />}>
            Copy MCP URL
          </Btn>
        ) : undefined}
      >
        <span className="settings-section-title">
          <Bot size={14} strokeWidth={1.8} />
          Agent connections
        </span>
      </SectionLabel>

      <Card>
        {data?.mcp_url ? (
          <div className="settings-row">
            <div className="settings-row-text">
              <div className="settings-row-label">DayPage Cloud MCP</div>
              <div className="settings-row-desc"><code>{data.mcp_url}</code></div>
            </div>
            <Chip tone="accent"><ShieldCheck size={12} /> OAuth protected</Chip>
          </div>
        ) : null}

        {data?.mcp_url && (isLoading || error || (data.connections?.length ?? 0) > 0) ? <div className="divider" /> : null}

        {isLoading ? (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>Loading connections…</div>
        ) : error ? (
          <div className="settings-row" role="alert" style={{ color: "var(--danger)", fontSize: "0.8125rem" }}>
            Connected apps are temporarily unavailable.
          </div>
        ) : !data?.connections.length ? (
          <div className="settings-row">
            <div className="settings-row-text">
              <div className="settings-row-label">No connected agents yet</div>
              <div className="settings-row-desc">
                Add the MCP URL to Codex or another compatible agent. DayPage will show a consent screen before sharing anything.
              </div>
            </div>
          </div>
        ) : data.connections.map((connection, index) => (
          <div key={connection.client.id}>
            {index > 0 ? <div className="divider" /> : null}
            <div className="settings-row">
              <div className="settings-row-text">
                <div className="settings-row-label" style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  {connection.client.name}
                  <Chip tone={connection.daypage_grant_active ? "accent" : "ghost"}>
                    {connection.can_write ? "read + write" : connection.can_read ? "read only" : "disabled"}
                  </Chip>
                </div>
                <div className="settings-row-desc">
                  Connected {new Date(connection.granted_at).toLocaleDateString()} · Identity scopes: {connection.scopes.join(", ") || "email"}
                  {connection.client.uri ? (
                    <> · <a href={connection.client.uri} target="_blank" rel="noreferrer">App details <ExternalLink size={11} style={{ display: "inline" }} /></a></>
                  ) : null}
                </div>
              </div>
              <div className="settings-row-control" style={{ display: "flex", gap: 8 }}>
                {connection.daypage_grant_active ? (
                  <Btn
                    kind="soft"
                    size="sm"
                    disabled={updateWrite.isPending}
                    onClick={() => updateWrite.mutate({ clientId: connection.client.id, canWrite: !connection.can_write })}
                  >
                    {connection.can_write ? "Make read-only" : "Allow adding memos"}
                  </Btn>
                ) : null}
                <Btn
                  kind="ghost"
                  size="sm"
                  icon={<Trash2 size={14} />}
                  disabled={revoke.isPending}
                  onClick={() => revoke.mutate(connection.client.id)}
                >
                  Revoke
                </Btn>
              </div>
            </div>
          </div>
        ))}

        {revoke.error ? (
          <div className="settings-row" role="alert" style={{ color: "var(--danger)", fontSize: "0.8125rem" }}>
            {revoke.error.message}
          </div>
        ) : null}
      </Card>
    </div>
  );
}
