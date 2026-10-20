// Personal invite links, for the person who received one: check a link, then use it to sign in once and
// choose a password. Called without a session, so it is deployed with JWT verification off; the link's
// token (256 random bits, stored only as a hash) is the proof.
import { admin, hashToken, preflight, reply } from '../_shared/library.ts';

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  try {
    const body = await req.json().catch(() => ({}));
    const token = String(body.token ?? '');
    if (!token || token.length > 100) return reply(req, 400, { valid: false, reason: 'unknown' });

    const { data: invite } = await admin.from('invites').select('token_hash, user_id, expires_at, used_at').eq('token_hash', await hashToken(token)).maybeSingle();
    if (!invite) return reply(req, 404, { valid: false, reason: 'unknown' });
    if (invite.used_at) return reply(req, 410, { valid: false, reason: 'used' });
    if (new Date(invite.expires_at) < new Date()) return reply(req, 410, { valid: false, reason: 'expired' });

    const { data: member } = await admin.from('members').select('email, display_name').eq('user_id', invite.user_id).maybeSingle();
    if (!member) return reply(req, 404, { valid: false, reason: 'unknown' });

    if (body.action === 'check') return reply(req, 200, { valid: true, email: member.email, name: member.display_name, expires_at: invite.expires_at });

    if (body.action === 'redeem') {
      // Close the link first, so it can be used only once, then hand back a one-time sign-in.
      const { data: closed } = await admin.from('invites').update({ used_at: new Date().toISOString() })
        .eq('token_hash', invite.token_hash).is('used_at', null).select('token_hash');
      if (!closed?.length) return reply(req, 410, { valid: false, reason: 'used' });
      const { data, error } = await admin.auth.admin.generateLink({ type: 'magiclink', email: member.email });
      if (error) throw error;
      return reply(req, 200, { valid: true, email: member.email, token_hash: data.properties.hashed_token });
    }

    return reply(req, 400, { error: 'Unknown action.' });
  } catch (err) {
    return reply(req, 500, { error: err instanceof Error ? err.message : String(err) });
  }
});
