// Supabase Edge Function — 새 예약(문의) 발생 시 카카오톡 "나에게 보내기"로 알림
// 배포 경로: supabase/functions/notify-kakao/index.ts
// 배포 후 Database Webhook(projects 테이블 INSERT)에서 이 함수를 호출하도록 연결합니다.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const KAKAO_REST_KEY = Deno.env.get("KAKAO_REST_API_KEY")!; // 카카오 개발자센터 REST API 키

const sb = createClient(SB_URL, SERVICE_KEY);

async function refreshKakaoToken(refreshToken: string) {
  const res = await fetch("https://kauth.kakao.com/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      client_id: KAKAO_REST_KEY,
      refresh_token: refreshToken
    })
  });
  if (!res.ok) throw new Error("카카오 토큰 갱신 실패: " + (await res.text()));
  return res.json(); // { access_token, refresh_token?, expires_in, ... }
}

async function sendKakaoMemo(accessToken: string, text: string) {
  const template = {
    object_type: "text",
    text,
    link: { web_url: "", mobile_web_url: "" }
  };
  const res = await fetch("https://kapi.kakao.com/v2/api/talk/memo/default/send", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + accessToken,
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: new URLSearchParams({ template_object: JSON.stringify(template) })
  });
  return res;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    // Database Webhook 표준 payload: { type, table, record, schema, old_record }
    const record = payload.record;
    if (!record || record.status !== "문의") return new Response("skip", { status: 200 });

    const studioId = record.studio_id;
    const { data: tok, error } = await sb
      .from("kakao_tokens")
      .select("access_token, refresh_token")
      .eq("studio_id", studioId)
      .maybeSingle();

    if (error || !tok) return new Response("no kakao token for studio", { status: 200 });

    const text =
      `📸 새 예약 문의\n` +
      `${record.bride} · ${record.groom}\n` +
      `${record.wedding_date} · ${record.venue ?? "장소 미정"}\n` +
      `${record.package_name ?? ""} · ${record.amount?.toLocaleString?.() ?? record.amount}원\n` +
      `연락처: ${record.phone}`;

    let res = await sendKakaoMemo(tok.access_token, text);

    if (res.status === 401) {
      // 토큰 만료 — 리프레시 후 1회 재시도
      const refreshed = await refreshKakaoToken(tok.refresh_token);
      await sb.from("kakao_tokens").update({
        access_token: refreshed.access_token,
        refresh_token: refreshed.refresh_token ?? tok.refresh_token,
        updated_at: new Date().toISOString()
      }).eq("studio_id", studioId);
      res = await sendKakaoMemo(refreshed.access_token, text);
    }

    if (!res.ok) return new Response("kakao send failed: " + (await res.text()), { status: 200 });
    return new Response("ok", { status: 200 });
  } catch (e) {
    return new Response("error: " + String(e), { status: 200 });
  }
});
