import "server-only";
import { auth, resolveUserId } from "./session";

export async function currentApiUserId(): Promise<string | null> {
  const session = await auth();
  if (!session?.user?.email) return null;
  return resolveUserId(session.user.email);
}
