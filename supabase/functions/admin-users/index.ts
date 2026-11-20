// admin-users: user management for KLS Delivery Tracker admins.
// Actions: list, create, update, reset_password, delete.
// Caller must be an active admin (checked against public.profiles).
// verify_jwt is off at the gateway; the caller's token is verified here with auth.getUser.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ROLES = ["admin", "editor", "viewer"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Identify caller from their JWT
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Not signed in" }, 401);
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  if (whoErr || !who?.user) return json({ error: "Not signed in" }, 401);
  const callerId = who.user.id;

  const { data: caller } = await admin.from("profiles").select("role,is_active").eq("id", callerId).single();
  if (!caller || !caller.is_active || caller.role !== "admin") return json({ error: "Admins only" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const action = String(body.action ?? "");

  // Prevent the last active admin from locking everyone out
  const wouldRemoveLastAdmin = async (targetId: string) => {
    const { data } = await admin.from("profiles").select("id").eq("role", "admin").eq("is_active", true);
    const others = (data ?? []).filter((r) => r.id !== targetId);
    return others.length === 0;
  };

  try {
    switch (action) {
      case "list": {
        const { data, error } = await admin.from("profiles")
          .select("id,email,full_name,role,is_active,created_at").order("created_at");
        if (error) throw error;
        // add last sign-in from auth
        const { data: au } = await admin.auth.admin.listUsers({ perPage: 1000 });
        const last = new Map((au?.users ?? []).map((u) => [u.id, u.last_sign_in_at]));
        return json({ users: (data ?? []).map((p) => ({ ...p, last_sign_in_at: last.get(p.id) ?? null })) });
      }

      case "create": {
        const email = String(body.email ?? "").trim().toLowerCase();
        const password = String(body.password ?? "");
        const full_name = String(body.full_name ?? "").trim() || email.split("@")[0];
        const role = String(body.role ?? "viewer");
        if (!email.includes("@")) return json({ error: "Valid email required" }, 400);
        if (password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);
        if (!ROLES.includes(role)) return json({ error: "Invalid role" }, 400);

        const { data, error } = await admin.auth.admin.createUser({
          email, password, email_confirm: true, user_metadata: { full_name },
        });
        if (error) throw error;
        const { error: pErr } = await admin.from("profiles")
          .update({ role, is_active: true, full_name }).eq("id", data.user.id);
        if (pErr) throw pErr;
        return json({ ok: true, id: data.user.id });
      }

      case "update": {
        const id = String(body.id ?? "");
        if (!id) return json({ error: "id required" }, 400);
        const patch: Record<string, unknown> = {};
        if (body.full_name !== undefined) patch.full_name = String(body.full_name).trim();
        if (body.role !== undefined) {
          if (!ROLES.includes(String(body.role))) return json({ error: "Invalid role" }, 400);
          patch.role = String(body.role);
        }
        if (body.is_active !== undefined) patch.is_active = Boolean(body.is_active);

        const demoting = (patch.role && patch.role !== "admin") || patch.is_active === false;
        if (demoting && await wouldRemoveLastAdmin(id)) {
          const { data: t } = await admin.from("profiles").select("role,is_active").eq("id", id).single();
          if (t?.role === "admin" && t?.is_active) return json({ error: "Can't remove the last active admin" }, 400);
        }

        const { error } = await admin.from("profiles").update(patch).eq("id", id);
        if (error) throw error;
        // Block / unblock sign-in at the auth level too
        if (patch.is_active !== undefined) {
          await admin.auth.admin.updateUserById(id, { ban_duration: patch.is_active ? "none" : "876000h" });
        }
        return json({ ok: true });
      }

      case "reset_password": {
        const id = String(body.id ?? "");
        const password = String(body.password ?? "");
        if (!id) return json({ error: "id required" }, 400);
        if (password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);
        const { error } = await admin.auth.admin.updateUserById(id, { password });
        if (error) throw error;
        return json({ ok: true });
      }

      case "delete": {
        const id = String(body.id ?? "");
        if (!id) return json({ error: "id required" }, 400);
        if (id === callerId) return json({ error: "You can't delete your own account" }, 400);
        const { data: t } = await admin.from("profiles").select("role,is_active").eq("id", id).single();
        if (t?.role === "admin" && t?.is_active && await wouldRemoveLastAdmin(id)) {
          return json({ error: "Can't delete the last active admin" }, 400);
        }
        const { error } = await admin.auth.admin.deleteUser(id);
        if (error) throw error;
        return json({ ok: true });
      }

      default:
        return json({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error).message ?? String(e) }, 400);
  }
});
