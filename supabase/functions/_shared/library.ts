// Shared pieces of the library's two functions: the service client, CORS, and invite tokens.
import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

export const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export const LIBRARY_URL = 'https://mira.science/library/';

const ORIGINS = ['https://mira.science', 'http://127.0.0.1:8765', 'http://localhost:8765'];
const PREVIEW = /^https:\/\/mira-landing-page-[a-z0-9-]+\.vercel\.app$/;

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') ?? '';
  return {
    'Access-Control-Allow-Origin': ORIGINS.includes(origin) || PREVIEW.test(origin) ? origin : ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

export function preflight(req: Request): Response | null {
  return req.method === 'OPTIONS' ? new Response('ok', { headers: corsHeaders(req) }) : null;
}

export function reply(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(req), 'Content-Type': 'application/json' } });
}

export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// A new personal link for one account. Earlier unused links for that account stop working.
export async function makeInvite(userId: string, createdBy: string, days: number): Promise<{ link: string; expires_at: string }> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const expires_at = new Date(Date.now() + days * 86400_000).toISOString();
  await admin.from('invites').delete().eq('user_id', userId).is('used_at', null);
  const { error } = await admin.from('invites').insert({ token_hash: await hashToken(token), user_id: userId, created_by: createdBy, expires_at });
  if (error) throw error;
  return { link: `${LIBRARY_URL}?invite=${token}`, expires_at };
}

export async function findUserByEmail(email: string) {
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const found = data.users.find((u) => (u.email ?? '').toLowerCase() === email);
    if (found || data.users.length < 1000) return found ?? null;
  }
}
