declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

type GcItem = {
  user_id: string;
  object_key: string;
  lease_token: string;
  attempt: number;
};

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const supabaseURL = required("SUPABASE_URL").replace(/\/$/, "");
const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY");
const workerSecret = required("DAYPAGE_ATTACHMENT_GC_SECRET");

const responseHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

async function rpc<T>(name: string, body: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${supabaseURL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "apikey": serviceRoleKey,
      "authorization": `Bearer ${serviceRoleKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`rpc_${name}_${response.status}`);
  return await response.json() as T;
}

async function removeObject(objectKey: string): Promise<void> {
  const response = await fetch(`${supabaseURL}/storage/v1/object/memo-attachments`, {
    method: "DELETE",
    headers: {
      "apikey": serviceRoleKey,
      "authorization": `Bearer ${serviceRoleKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ prefixes: [objectKey] }),
  });
  if (!response.ok) throw new Error(`storage_delete_${response.status}`);
}

async function finish(item: GcItem, deleted: boolean, errorCode?: string): Promise<boolean> {
  return await rpc<boolean>("daypage_finish_attachment_gc", {
    p_user_id: item.user_id,
    p_object_key: item.object_key,
    p_lease_token: item.lease_token,
    p_deleted: deleted,
    p_error_code: errorCode ?? null,
  });
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: responseHeaders,
    });
  }
  if (request.headers.get("authorization") !== `Bearer ${workerSecret}`) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: responseHeaders,
    });
  }

  try {
    const requested = Number(request.headers.get("x-daypage-gc-limit") ?? "25");
    const limit = Math.min(Math.max(Number.isFinite(requested) ? Math.trunc(requested) : 25, 1), 100);
    const inventory = await rpc<{ queued: number }>(
      "daypage_inventory_attachment_orphans",
      {},
    );
    const claimed = await rpc<{ items: GcItem[] }>(
      "daypage_claim_attachment_gc",
      { p_limit: limit },
    );

    let deleted = 0;
    let retried = 0;
    for (const item of claimed.items) {
      try {
        await removeObject(item.object_key);
        if (await finish(item, true)) deleted += 1;
      } catch (error) {
        const errorCode = error instanceof Error ? error.message : "storage_api_error";
        await finish(item, false, errorCode);
        retried += 1;
      }
    }

    // Deliberately bounded, content-free metrics: no filenames, object keys,
    // transcripts, URLs, credentials, or bytes are returned or logged.
    return new Response(JSON.stringify({
      inventoried: inventory.queued,
      claimed: claimed.items.length,
      deleted,
      retried,
    }), { headers: responseHeaders });
  } catch {
    return new Response(JSON.stringify({ error: "worker_failed" }), {
      status: 500,
      headers: responseHeaders,
    });
  }
});
