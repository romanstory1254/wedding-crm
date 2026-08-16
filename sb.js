// Supabase 연동 — 멀티 스튜디오 웨딩 CRM
export const SB_URL = 'https://jitajqvdquowumxowkdq.supabase.co';
export const SB_KEY = 'sb_publishable_rY0uK04Qd84LMeY7H_ITKQ_a7zByiYK';

const TOKEN_KEY = 'rs_sb_session';

/* ── 공개 페이지가 어느 스튜디오를 보여줄지 ──
   ?studio=romancestory  또는  /s/romancestory  에서 읽습니다. */
export function currentSlug() {
  try {
    const q = new URLSearchParams(location.search).get('studio');
    if (q) return q;
    const m = location.pathname.match(/\/s\/([a-z0-9-]+)/i);
    if (m) return m[1];
  } catch (e) {}
  try { return localStorage.getItem('rs_slug') || 'eodnd1254'; } catch (e) { return 'eodnd1254'; }
}
export function setSlug(slug) { try { localStorage.setItem('rs_slug', slug); } catch (e) {} }

export function getSession() {
  try { return JSON.parse(localStorage.getItem(TOKEN_KEY) || 'null'); } catch (e) { return null; }
}
function setSession(s) {
  try {
    if (s) localStorage.setItem(TOKEN_KEY, JSON.stringify(s));
    else localStorage.removeItem(TOKEN_KEY);
  } catch (e) {}
}

function headers(auth) {
  const h = { apikey: SB_KEY, 'Content-Type': 'application/json' };
  const s = auth && getSession();
  h.Authorization = 'Bearer ' + (s && s.access_token ? s.access_token : SB_KEY);
  return h;
}

async function req(path, opts = {}, auth = true) {
  const res = await fetch(SB_URL + path, {
    method: opts.method || 'GET',
    headers: Object.assign(headers(auth), opts.headers || {}),
    body: opts.body ? JSON.stringify(opts.body) : undefined
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { data = text; }
  if (!res.ok) {
    const err = new Error((data && (data.message || data.error_description || data.msg)) || res.status);
    err.code = data && data.code;
    err.status = res.status;
    throw err;
  }
  return data;
}

/* 마이그레이션(supabase-multitenant.sql) 실행 전이면 구버전 함수로 자동 폴백 */
export const MISSING = e => e && (e.code === 'PGRST202' || e.code === 'PGRST205' || e.status === 404);
const SETUP_MSG = '이 기능은 supabase-features.sql 을 실행해야 사용할 수 있어요.';
export let legacyMode = false;
async function rpcCompat(fn, args, legacyArgs) {
  try {
    return await rpcPub(fn, args);
  } catch (e) {
    if (MISSING(e) && legacyArgs !== undefined) { legacyMode = true; return rpcPub(fn, legacyArgs); }
    throw e;
  }
}

const rpcPub = (fn, args) => req('/rest/v1/rpc/' + fn, { method: 'POST', body: args || {} }, false);

/* ── 인증 ─────────────────────────────────────── */
export const PROVIDERS = [
  { id: 'kakao',  label: '카카오로 시작하기', bg: '#fee500', fg: '#191600', native: true },
  { id: 'google', label: '구글로 시작하기',   bg: '#ffffff', fg: '#191f28', native: true, border: true }
];

export function oauthUrl(provider, extraScopes) {
  const redirect = location.origin + '/';
  let url = `${SB_URL}/auth/v1/authorize?provider=${provider}&redirect_to=${encodeURIComponent(redirect)}`;
  if (extraScopes) url += `&scopes=${encodeURIComponent(extraScopes)}`;
  return url;
}
export function signInWithProvider(provider, extraScopes) { location.href = oauthUrl(provider, extraScopes); }

/* OAuth 리디렉션으로 돌아왔을 때 URL 해시의 토큰을 저장 */
export function captureRedirect() {
  const h = location.hash || '';
  if (h.indexOf('access_token') === -1) {
    if (h.indexOf('error') !== -1) {
      const p = new URLSearchParams(h.slice(1));
      return { error: p.get('error_description') || p.get('error') };
    }
    return null;
  }
  const p = new URLSearchParams(h.slice(1));
  const sess = {
    access_token: p.get('access_token'),
    refresh_token: p.get('refresh_token'),
    expires_at: Number(p.get('expires_at') || 0)
  };
  setSession(sess);
  const providerToken = p.get('provider_token');
  const providerRefreshToken = p.get('provider_refresh_token');
  history.replaceState(null, '', location.pathname + location.search);
  return { ok: true, providerToken, providerRefreshToken };
}

export async function saveKakaoToken(accessToken, refreshToken) {
  if (!accessToken || !refreshToken) return;
  try { await rpcAuth('save_kakao_token', { p_access_token: accessToken, p_refresh_token: refreshToken }); }
  catch (e) { /* 마이그레이션 전이면 무시 */ }
}

export async function signIn(email, password) {
  const res = await fetch(SB_URL + '/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: { apikey: SB_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error_description || data.msg || '로그인에 실패했습니다');
  setSession(data);
  return data;
}
export function signOut() { setSession(null); }
export function isSignedIn() { const s = getSession(); return !!(s && s.access_token); }

export async function fetchUser() {
  const s = getSession();
  if (!s || !s.access_token) return null;
  try {
    const u = await req('/auth/v1/user');
    if (u) { setSession({ ...s, user: u }); }
    return u;
  } catch (e) { return null; }
}
export function sessionEmail() {
  const s = getSession();
  if (!s || !s.user) return '';
  return s.user.email || (s.user.user_metadata && s.user.user_metadata.name) || '';
}

/* ── 스튜디오 (테넌트) ────────────────────────── */
const rpcAuth = (fn, args) => req('/rest/v1/rpc/' + fn, { method: 'POST', body: args || {} }, true);

export async function ensureStudio(name) {
  try {
    await rpcAuth('ensure_studio', { p_name: name || null });
    const r = await rpcAuth('my_studio', {});
    const st = r && r.length ? r[0] : null;
    if (st) setSlug(st.slug);
    return st;
  } catch (e) {
    if (MISSING(e)) { legacyMode = true; return { id: null, slug: currentSlug(), name: '로맨스토리', role: 'owner', legacy: true }; }
    throw e;
  }
}

/* ── 필드 매핑 ────────────────────────────────── */
const toApp = r => ({
  id: r.id, groom: r.groom, bride: r.bride, createdAt: r.created_at,
  checklist: r.checklist || [], files: r.timeline_files || [], repliedAt: r.first_replied_at,
  viewCount: r.view_count || 0, lastViewedAt: r.last_viewed_at,
  name: r.display_name || `${r.bride} · ${r.groom}`,
  phone: r.phone, source: r.source || '미확인',
  date: r.wedding_date, venue: r.venue || '미정', travel: r.venue_region || '',
  pkg: r.package_name || '', amount: r.amount || 0, paid: r.paid || 0,
  status: r.status, editStage: r.edit_stage,
  timeline: r.timeline || '', shotlist: r.shotlist || '',
  youtube: r.youtube_url || '', drive: r.drive_url || '', invoice: r.invoice_no || '',
  memo: r.memo || ''
});

const APP2DB = {
  status: 'status', editStage: 'edit_stage', amount: 'amount', paid: 'paid',
  youtube: 'youtube_url', drive: 'drive_url', invoice: 'invoice_no',
  timeline: 'timeline', shotlist: 'shotlist', venue: 'venue',
  date: 'wedding_date', pkg: 'package_name', phone: 'phone', memo: 'memo',
  checklist: 'checklist', repliedAt: 'first_replied_at', files: 'timeline_files'
};
function toDb(patch) {
  const out = {};
  Object.keys(patch).forEach(k => { if (APP2DB[k]) out[APP2DB[k]] = patch[k]; });
  return out;
}

/* ── 관리자 데이터 ────────────────────────────── */
export async function listProjects() {
  const rows = await req('/rest/v1/projects?select=*&order=wedding_date.asc');
  return (rows || []).map(toApp);
}
export async function updateProject(id, patch) {
  const body = toDb(patch);
  if (!Object.keys(body).length) return;
  await req(`/rest/v1/projects?id=eq.${id}`, { method: 'PATCH', body, headers: { Prefer: 'return=minimal' } });
}
export async function deleteProject(id) {
  await req('/rest/v1/projects?id=eq.' + id, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
}
export async function addPayment(projectId, kind, amount, method, payer) {
  await req('/rest/v1/payments', {
    method: 'POST',
    body: { project_id: projectId, kind, amount, method: method || 'transfer', payer_name: payer || null },
    headers: { Prefer: 'return=minimal' }
  });
}

/* ── 설정 ─────────────────────────────────────── */
export async function loadSettings(slug) {
  let rows;
  try {
    rows = await rpcPub('get_public_settings', { p_slug: slug || currentSlug() });
  } catch (e) {
    if (!MISSING(e)) throw e;
    legacyMode = true;
    rows = await req('/rest/v1/app_settings?select=key,value', {}, false);
  }
  const out = {};
  (rows || []).forEach(r => { out[r.key] = r.value; });
  return out;
}
export async function saveSetting(key, value, studioId) {
  await req('/rest/v1/app_settings', {
    method: 'POST',
    body: { studio_id: studioId, key, value },
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }
  });
}

/* ── 방문자용 RPC ─────────────────────────────── */
export const bookedDates = slug => rpcCompat('get_public_booking_dates', { p_slug: slug || currentSlug() }, {});
export const monthLoad = slug => rpcCompat('get_month_load', { p_slug: slug || currentSlug() }, {});

export async function verifyClient(name, phone, slug) {
  const r = await rpcCompat('verify_client_booking',
    { p_slug: slug || currentSlug(), p_name: name, p_phone: phone },
    { p_name: name, p_phone: phone });
  if (!r || !r.length) return null;
  const x = r[0];
  return {
    id: x.id, name: x.display_name, date: x.wedding_date, venue: x.venue,
    pkg: x.package_name, status: x.status, editStage: x.edit_stage,
    amount: x.amount, paid: x.paid, balance: x.balance,
    timeline: x.timeline || '', shotlist: x.shotlist || '', files: x.timeline_files || [],
    youtube: x.youtube_url || '', drive: x.drive_url || '', invoice: x.invoice_no || ''
  };
}

export async function paymentSummary(name, phone, slug) {
  const r = await rpcCompat('get_payment_summary',
    { p_slug: slug || currentSlug(), p_name: name, p_phone: phone },
    { p_name: name, p_phone: phone });
  if (!r || !r.length) return null;
  const x = r[0];
  return {
    id: x.id, name: x.display_name, date: x.wedding_date, pkg: x.package_name,
    amount: x.amount, paid: x.paid, balance: x.balance, depositDue: x.deposit_due
  };
}

export const blackoutDates = slug =>
  rpcPub('get_blackout_dates', { p_slug: slug || currentSlug() }).catch(e => (MISSING(e) ? [] : Promise.reject(e)));

export async function listBlackouts() {
  return req('/rest/v1/blackout_dates?select=id,date,reason&order=date.asc').catch(e => (MISSING(e) ? [] : Promise.reject(e)));
}
export async function addBlackout(date, reason) {
  try {
    return await req('/rest/v1/blackout_dates', { method: 'POST', body: { date, reason: reason || null }, headers: { Prefer: 'return=representation' } });
  } catch (e) { throw new Error(MISSING(e) ? SETUP_MSG : (e.message || e)); }
}
export async function removeBlackout(id) {
  try {
    return await req('/rest/v1/blackout_dates?id=eq.' + id, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
  } catch (e) { throw new Error(MISSING(e) ? SETUP_MSG : (e.message || e)); }
}

/* 관리자용 파일 업로드 (프로젝트에 직접 첨부 — RPC 없이 storage만 사용) */
export async function uploadFile(file, slug) {
  const safe = file.name.replace(/[^\w.\-]/g, '_');
  const path = `${(slug || currentSlug())}/admin_${Date.now()}_${safe}`;
  const res = await fetch(`${SB_URL}/storage/v1/object/client-files/${encodeURI(path)}`, {
    method: 'POST',
    headers: Object.assign(headers(true), { 'x-upsert': 'true', 'Content-Type': file.type || 'application/octet-stream' }),
    body: file
  });
  if (!res.ok) {
    if (res.status === 404) throw new Error(SETUP_MSG);
    let detail = '';
    try { detail = (await res.json()).message || ''; } catch (e) {}
    throw new Error('업로드 실패' + (detail ? ': ' + detail : ' (' + res.status + ')'));
  }
  return `${SB_URL}/storage/v1/object/public/client-files/${encodeURI(path)}`;
}

/* 고객 식순표 업로드 */
export async function uploadClientFile(file, name, phone, slug) {
  // Supabase Storage 키는 ASCII만 허용 — 한글·특수문자는 치환 (원본 파일명은 별도로 저장됨)
  const safe = file.name.replace(/[^\w.\-]/g, '_');
  const path = `${(slug || currentSlug())}/${Date.now()}_${safe}`;
  const res = await fetch(`${SB_URL}/storage/v1/object/client-files/${encodeURI(path)}`, {
    method: 'POST',
    headers: {
      apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'x-upsert': 'true',
      'Content-Type': file.type || 'application/octet-stream'
    },
    body: file
  });
  if (!res.ok) {
    if (res.status === 404) throw new Error(SETUP_MSG);
    let detail = '';
    try { detail = (await res.json()).message || ''; } catch (e) {}
    throw new Error('업로드 실패' + (detail ? ': ' + detail : ' (' + res.status + ')'));
  }
  const url = `${SB_URL}/storage/v1/object/public/client-files/${encodeURI(path)}`;
  let ok;
  try {
    ok = await rpcPub('attach_client_file', {
      p_slug: slug || currentSlug(), p_name: name, p_phone: phone, p_url: url, p_filename: file.name
    });
  } catch (e) { throw new Error(MISSING(e) ? SETUP_MSG : (e.message || e)); }
  if (!ok) throw new Error('예약 정보를 찾을 수 없어요');
  return url;
}

export async function submitInquiry(b, slug) {
  const core = {
    p_groom: b.groom, p_bride: b.bride, p_phone: b.phone, p_date: b.date,
    p_venue: b.venue || null, p_region: b.travel || null,
    p_package_id: b.pkgId || null, p_package_name: b.pkgName || null,
    p_options: b.options || [], p_sns: !!b.sns, p_amount: b.amount || 0,
    p_source: b.source || null, p_memo: [b.snapStudio ? `동행 스냅업체: ${b.snapStudio}` : '', b.memo || ''].filter(Boolean).join('\n')
  };
  return rpcCompat('submit_inquiry', Object.assign({ p_slug: slug || currentSlug() }, core), core);
}
