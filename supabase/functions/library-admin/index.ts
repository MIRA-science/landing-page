// Library admin actions, for members marked as admins: list members, invite someone by email (an account
// plus a personal link to choose a password), make a new link, add a Gmail address someone wants to sign in
// with, and remove someone's access.
import { admin, findUserByEmail, makeInvite, preflight, reply } from '../_shared/library.ts';

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  try {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return reply(req, 401, { error: 'Sign in first.' });
    const { data: me } = await admin.from('members').select('is_admin').eq('user_id', user.id).maybeSingle();
    if (!me?.is_admin) return reply(req, 403, { error: 'Only library admins can do this.' });

    const body = await req.json().catch(() => ({}));
    const days = Math.min(90, Math.max(1, Math.round(Number(body.days) || 30)));

    switch (body.action) {
      case 'list': {
        const [{ data: members, error }, { data: invites }] = await Promise.all([
          admin.from('members').select('user_id, email, display_name, is_admin, alias_of, added_at').order('added_at'),
          admin.from('invites').select('user_id, created_at, expires_at, used_at'),
        ]);
        if (error) throw error;
        const users = new Map<string, { last_sign_in_at?: string; providers: string[] }>();
        for (let page = 1; ; page++) {
          const { data } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
          for (const u of data.users) users.set(u.id, { last_sign_in_at: u.last_sign_in_at, providers: (u.identities ?? []).map((i) => i.provider) });
          if (data.users.length < 1000) break;
        }
        return reply(req, 200, {
          members: members.map((m) => {
            const mine = (invites ?? []).filter((i) => i.user_id === m.user_id).sort((a, b) => b.created_at.localeCompare(a.created_at));
            return { ...m, ...users.get(m.user_id), password_set: mine.some((i) => i.used_at), invite: mine.find((i) => !i.used_at) ?? null };
          }),
        });
      }

      case 'invite': {
        const email = String(body.email ?? '').trim().toLowerCase();
        const name = String(body.name ?? '').trim();
        if (!EMAIL.test(email)) return reply(req, 400, { error: 'That doesn’t look like an email address.' });
        if (!name) return reply(req, 400, { error: 'Give their name.' });
        let account = await findUserByEmail(email);
        if (account) {
          const { data: member } = await admin.from('members').select('user_id').eq('user_id', account.id).maybeSingle();
          if (member) return reply(req, 409, { error: 'They’re already a member. Use “New link” on their entry instead.' });
        } else {
          const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { full_name: name } });
          if (error) throw error;
          account = data.user;
        }
        const { error } = await admin.from('members').insert({ user_id: account.id, email, display_name: name });
        if (error) throw error;
        return reply(req, 200, { email, name, ...(await makeInvite(account.id, user.id, days)) });
      }

      case 'new-link': {
        const { data: member } = await admin.from('members').select('user_id, email, display_name, alias_of').eq('user_id', body.user_id).maybeSingle();
        if (!member || member.alias_of) return reply(req, 404, { error: 'No such member.' });
        return reply(req, 200, { email: member.email, name: member.display_name, ...(await makeInvite(member.user_id, user.id, days)) });
      }

      case 'add-google': {
        const email = String(body.email ?? '').trim().toLowerCase();
        if (!EMAIL.test(email)) return reply(req, 400, { error: 'That doesn’t look like an email address.' });
        const { data: member } = await admin.from('members').select('user_id, display_name, alias_of').eq('user_id', body.user_id).maybeSingle();
        if (!member || member.alias_of) return reply(req, 404, { error: 'No such member.' });
        let account = await findUserByEmail(email);
        if (account) {
          const { data: taken } = await admin.from('members').select('user_id').eq('user_id', account.id).maybeSingle();
          if (taken) return reply(req, 409, { error: 'That address is already on the list.' });
        } else {
          const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { full_name: member.display_name } });
          if (error) throw error;
          account = data.user;
        }
        const { error } = await admin.from('members').insert({ user_id: account.id, email, display_name: member.display_name, alias_of: member.user_id });
        if (error) throw error;
        return reply(req, 200, { ok: true });
      }

      case 'remove': {
        if (body.user_id === user.id) return reply(req, 400, { error: 'You can’t remove yourself.' });
        const { data: member } = await admin.from('members').select('user_id').eq('user_id', body.user_id).maybeSingle();
        if (!member) return reply(req, 404, { error: 'No such member.' });
        const { data: aliases } = await admin.from('members').select('user_id').eq('alias_of', body.user_id);
        for (const id of [...(aliases ?? []).map((a) => a.user_id), body.user_id]) {
          const { error } = await admin.auth.admin.deleteUser(id);
          if (error) throw error;
        }
        return reply(req, 200, { ok: true });
      }

      default:
        return reply(req, 400, { error: 'Unknown action.' });
    }
  } catch (err) {
    return reply(req, 500, { error: err instanceof Error ? err.message : String(err) });
  }
});
