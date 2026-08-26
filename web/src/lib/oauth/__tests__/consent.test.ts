import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createClient: vi.fn(),
  getAuthorizationDetails: vi.fn(),
  approveAuthorization: vi.fn(),
  denyAuthorization: vi.fn(),
  upsert: vi.fn(),
  update: vi.fn(),
  firstEq: vi.fn(),
  secondEq: vi.fn(),
}));

vi.mock("@/lib/supabase/server", () => ({
  createClient: mocks.createClient,
}));

import { approveConsent, denyConsent } from "../consent";

const details = {
  authorization_id: "authorization-1",
  user: { id: "user-1", email: "owner@example.test" },
  client: { id: "client-1", name: "Test client", uri: null },
  scope: "openid email profile",
};

function configureClient() {
  const updateChain = {
    eq: mocks.firstEq,
  };
  mocks.firstEq.mockReturnValue({ eq: mocks.secondEq });
  mocks.secondEq.mockResolvedValue({ error: null });
  mocks.update.mockReturnValue(updateChain);

  const grants = {
    upsert: mocks.upsert,
    update: mocks.update,
  };
  const client = {
    auth: {
      oauth: {
        getAuthorizationDetails: mocks.getAuthorizationDetails,
        approveAuthorization: mocks.approveAuthorization,
        denyAuthorization: mocks.denyAuthorization,
      },
    },
    from: vi.fn().mockReturnValue(grants),
  };
  mocks.createClient.mockResolvedValue(client);
  return client;
}

describe("OAuth consent grant transaction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    configureClient();
    mocks.getAuthorizationDetails.mockResolvedValue({ data: details, error: null });
    mocks.upsert.mockResolvedValue({ error: null });
    mocks.approveAuthorization.mockResolvedValue({
      data: { redirect_url: "http://client.example/callback?code=accepted" },
      error: null,
    });
    mocks.denyAuthorization.mockResolvedValue({
      data: { redirect_url: "http://client.example/callback?error=access_denied" },
      error: null,
    });
  });

  it("persists the exact client grant before approving OAuth", async () => {
    const result = await approveConsent("authorization-1", "client-1", true);

    expect(result.redirectUrl).toContain("code=accepted");
    expect(mocks.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: "user-1",
        client_id: "client-1",
        can_read: true,
        can_write: true,
        revoked_at: null,
      }),
      { onConflict: "user_id,client_id" },
    );
    expect(mocks.upsert.mock.invocationCallOrder[0])
      .toBeLessThan(mocks.approveAuthorization.mock.invocationCallOrder[0]);
    expect(mocks.approveAuthorization).toHaveBeenCalledWith(
      "authorization-1",
      { skipBrowserRedirect: true },
    );
  });

  it("rejects an authorization ID paired with another client", async () => {
    await expect(approveConsent("authorization-1", "client-2", false))
      .rejects.toThrow("OAuth client mismatch");
    expect(mocks.upsert).not.toHaveBeenCalled();
    expect(mocks.approveAuthorization).not.toHaveBeenCalled();
  });

  it("does not approve OAuth when the DayPage grant cannot be saved", async () => {
    mocks.upsert.mockResolvedValueOnce({ error: { message: "database unavailable" } });

    await expect(approveConsent("authorization-1", "client-1", false))
      .rejects.toThrow("DayPage permission could not be saved");
    expect(mocks.approveAuthorization).not.toHaveBeenCalled();
  });

  it("revokes the DayPage grant when Supabase approval fails", async () => {
    mocks.approveAuthorization.mockResolvedValueOnce({
      data: null,
      error: { message: "authorization expired" },
    });

    await expect(approveConsent("authorization-1", "client-1", false))
      .rejects.toThrow("OAuth authorization could not be completed");
    expect(mocks.update).toHaveBeenCalledWith(expect.objectContaining({
      revoked_at: expect.any(String),
      updated_at: expect.any(String),
    }));
    expect(mocks.firstEq).toHaveBeenCalledWith("user_id", "user-1");
    expect(mocks.secondEq).toHaveBeenCalledWith("client_id", "client-1");
  });

  it("denies through Supabase without creating a DayPage grant", async () => {
    const result = await denyConsent("authorization-1");

    expect(result.redirectUrl).toContain("error=access_denied");
    expect(mocks.denyAuthorization).toHaveBeenCalledWith(
      "authorization-1",
      { skipBrowserRedirect: true },
    );
    expect(mocks.upsert).not.toHaveBeenCalled();
  });
});
