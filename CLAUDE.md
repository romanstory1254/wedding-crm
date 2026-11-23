# 로맨스토리 웨딩 CRM — Claude Code 작업 설명서

이 저장소는 1인 웨딩 영상 스튜디오 **로맨스토리**(대표 엄대웅)의 실제 운영 중인 홈페이지 + 예약 + 관리자 CRM입니다.
이 파일을 먼저 끝까지 읽고 작업하세요. 사용자는 개발자가 아니므로 **설명은 한국어로, 쉽고 짧게, 단계별로** 해주세요.

---

## 1. 한눈에 보기

| 항목 | 값 |
|---|---|
| 실제 주소 | https://roman-story.com (가비아 도메인 → GitHub Pages) |
| 관리자 화면 | https://roman-story.com/?umde1254 (상단에 '관리자' 탭이 생김 → 카카오/구글 로그인) |
| 배포 방식 | GitHub 저장소 `main` 브랜치에 push → GitHub Pages가 1~2분 뒤 자동 반영 |
| 백엔드 | Supabase (프로젝트 ref `jitajqvdquowumxowkdq`) — DB, 로그인, 파일 저장, RPC, Edge Function |
| 스튜디오 slug | `eodnd1254` (공개 페이지가 어떤 스튜디오 데이터를 보여줄지 결정) |
| 빌드 도구 | **없음.** 정적 파일 그대로 배포. npm/번들러 사용 안 함 |
| 예전 호스팅 | Netlify(gentle-froyo-8323fc.netlify.app) → 현재는 사용 안 함 |

---

## 2. 파일 구조

```
romanstory-crm/
├─ index.html          ← 앱 전체 (홈페이지 + 결제 + 고객조회 + 관리자 CRM). 거의 모든 수정은 여기
├─ sb.js               ← Supabase 통신 모듈 (REST/RPC/Storage/로그인). index.html이 import
├─ support.js          ← index.html 실행용 런타임. **절대 수정 금지**
├─ doc-page.js         ← 보조 스크립트. 수정 금지
├─ CNAME               ← roman-story.com (GitHub Pages 커스텀 도메인). 삭제 금지
├─ assets/logo.png     ← 상단/푸터 로고
├─ CLAUDE.md           ← 이 문서
└─ supabase/
   ├─ functions/notify-kakao/index.ts   ← 새 예약 시 대표 카톡으로 알림 (Edge Function)
   └─ sql/01~10-*.sql                   ← DB 스키마/RPC 이력 (모두 이미 실행 완료)
```

---

## 3. index.html 구조 (중요 — 일반 React 파일이 아님)

`index.html`은 support.js가 해석하는 **템플릿 + 로직 클래스** 형식입니다.

```
<head> … <script src="./support.js"> …
<x-dc>
  <helmet> 폰트, html2pdf CDN, <style>(body 리셋·@keyframes·html.sky 다크테마 CSS) </helmet>
  … 화면 마크업 (인라인 style 위주) …
</x-dc>
<script type="text/x-dc" data-dc-script data-props="…">
  const 상수들…
  class Component extends DCLogic {
    state = { appMode: 'home', view: 'dashboard', … };
    renderVals() { const v = {}; … return v; }   // 템플릿에 넘길 값 전부 여기서 계산
  }
</script>
```

### 템플릿 문법 규칙 (반드시 지킬 것)
- `{{ path }}` 는 **점(.) 경로 조회만** 가능: `{{ booking.date }}`, `{{ p.name }}`.
  `{{ a + b }}`, `{{ !x }}`, `{{ fn() }}`, 삼항식 **불가** → `renderVals()`에서 계산해 이름을 붙여 넘길 것.
- 반복: `<sc-for list="{{ items }}" as="item" hint-placeholder-count="3"> … </sc-for>` (`$index` 사용 가능)
- 조건: `<sc-if value="{{ flag }}" hint-placeholder-val="{{ false }}"> … </sc-if>`
  부정 조건은 `noXxx` 같은 별도 불리언을 renderVals에서 만들어 사용.
- 이벤트: `onClick="{{ handler }}"`, `onChange="{{ handler }}"` (JSX camelCase). `class`/`for` 그대로 써도 됨.
- 스타일은 대부분 **인라인 style**. 새 CSS 클래스 추가는 피하고, 꼭 필요하면 helmet의 `<style>` 안에만.
- 모든 태그는 명시적으로 닫기, 속성값은 큰따옴표.

### 주요 state / 화면
- `appMode`: `home`(홈페이지) · `pay`(결제) · `client`(고객 조회) · `admin`(관리자)
- `view`(관리자 내부): `dashboard` · `pipeline`(워크플로우 칸반) · `calendar` · `analytics`(마케팅) · `tax`(세금 관리) · `contracts` · `cms`(홈페이지 관리)
- `config`: 홈페이지 문구/패키지/옵션/출장비/FAQ/후기/갤러리 등 **CMS 데이터**. 기본값은 state 초기값에 있고,
  Supabase `app_settings`(키: `homepage`, `pricing`, `checklist`, `calendar`)에 저장된 값이 **기본값을 덮어씀**.
- `booking`: 예약 폼 입력값. localStorage `rs_booking_draft`에 자동 저장/복구.

> ⚠️ **자주 헷갈리는 점:** 코드의 기본 문구를 바꿔도, Supabase에 이미 저장된 값이 있으면 화면은 저장된 값을 씁니다.
> 문구 변경 시 (1) 코드 기본값 수정 + (2) 필요하면 로드 시점(`merge(...)` 근처)에서 구버전 데이터를 보정하는 코드 추가 + (3) 사용자에게 "관리자 → 홈페이지 관리 → 저장"을 한 번 눌러달라고 안내.

---

## 4. Supabase

- URL/공개키는 `sb.js` 상단 (`sb_publishable_…` — 공개용이라 코드에 있어도 됨).
- **secret 키(sb_secret_…)는 절대 코드·문서·커밋에 넣지 말 것.**
- 공개 방문자는 전체 데이터를 못 읽고 **RPC**로만 접근:
  `get_public_booking_dates`, `get_month_load`, `get_blackout_dates`, `verify_client_booking`, `get_payment_summary`,
  `submit_inquiry`(예약 접수, 예식시간 `p_time` 포함), `attach_client_file`, `submit_receipt_request`(현금영수증/세금계산서), `track_event`
- 관리자는 로그인 토큰으로 `projects`, `payments`, `app_settings`, `blackout_dates` 직접 CRUD (RLS로 본인 스튜디오만).
- Storage 버킷: `client-files` (파일 키는 ASCII만 허용 → 한글 파일명은 치환해서 저장).
- 테이블 주요 컬럼(projects): groom, bride, phone, phone_digits, wedding_date, wedding_time, venue, venue_region,
  package_id/name, options(jsonb), sns_agreed, amount, paid, balance, status(문의/예약/촬영/편집/납품), edit_stage,
  timeline/shotlist/timeline_files, youtube_url, drive_url, invoice_no, memo, snap_studio, source, receipt_request(jsonb), view_count 등.
- DB 구조를 바꿀 때는 `supabase/sql/`에 **새 번호 파일**로 추가하고, 사용자에게 Supabase 대시보드 → SQL Editor에 붙여넣어 Run 하도록 안내.
  `drop` 이 들어가면 "destructive operation" 경고가 뜬다는 것도 미리 설명.
- plpgsql 함수에서 `RETURNS TABLE(id …)` 와 컬럼명이 겹치면 "column reference is ambiguous" 에러 → 테이블 별칭(`p.id`)으로 항상 한정할 것.

### 카카오 알림 (Edge Function)
- `supabase/functions/notify-kakao/index.ts` — projects INSERT 시 Database Webhook이 호출 → 대표 카톡 "나에게 보내기".
- 시크릿 `KAKAO_REST_API_KEY` 는 Supabase secrets에 이미 설정됨.
- 수정 후 배포: 저장소 루트에서
  ```
  supabase link --project-ref jitajqvdquowumxowkdq   (최초 1회)
  supabase functions deploy notify-kakao --no-verify-jwt
  ```
  ("Docker is not running" 경고는 무시해도 됨)
- ⚠️ 현재 서버에 배포된 버전은 **예식시간이 알림에 안 나오는 이전 버전**일 수 있음. 저장소의 index.ts가 최신(예식시간 포함). 사용자가 원하면 위 명령으로 재배포.

### 로그인
- 관리자 로그인: Supabase Auth의 **카카오 / 구글 OAuth** (네이버 제외).
- Supabase → Authentication → URL Configuration 의 Site URL / Redirect URLs 에 `https://roman-story.com` 계열이 등록돼 있어야 함.
  로그인 후 `localhost:3000`으로 튕기면 이 설정 문제.
- 카카오 동의항목: 닉네임·프로필사진·이메일 + 카카오톡 메시지 전송(talk_message). 비즈 앱 전환 완료.

---

## 5. 사업/콘텐츠 정보 (문구 작성 시 참고)

- 상호 로맨스토리 · 대표 엄대웅 · 사업자등록번호 891-62-00670
- 입금 계좌: 하나은행 756-910345-81707 (엄대웅 로맨스토리)
- 카카오톡 채널: http://pf.kakao.com/_xdzVyn/chat · 인스타 @romanstory_wedding · 이메일 eodnd1254@naver.com
- 대표 거주지: 서울 노원 (출장비 기준점)
- 월 8팀 한정, 전 상품 4K 촬영, 촬영일 기준 1개월 이내 USB 납품, 1인 대표 직접 상담·촬영·편집
- 패키지: 베이직 49만 / 시그니처 59만(BEST, 짐벌 포함) / 프레스티지 99만(2인 5캠, 드론 인트로) — SNS 동의 시 4만 원 할인 (예약 폼에서 SNS 동의는 기본 체크 상태)
  - 편집물 공통 표현: "신부대기실 · 본식 · 원판촬영 챕터별 풀영상 제공". 하이라이트 3~5분은 시그니처·프레스티지만 (베이직은 "하이라이트 영상 미제공")
  - 전 상품 공통: 신부대기실 1시간 전~원판 종료 촬영, 포토테이블 무인캠
- 일요일 예식 5만 원 할인. 성수기 날짜는 "예약 가능(초록)" + "성수기 마감 주의(노랑)" 두 박스로 안내
- 출장비: 수도권 무료 / 경기 외곽(포천·동두천·연천·가평·양평·여주·이천·안성) 5만 원 / 충청·강원 7~10만 / 경상·전라 15~20만 / 제주 별도 협의
  → 견적에는 **구간 상한가**로 계산
- 결제는 **계좌이체만** (토스·카카오 간편결제는 제거됨). 현금영수증은 잔금 정산 후 발급.
- 후기는 실제 말투(ㅎㅎ, 이모지 🧡✨), 이름 익명, "날짜 · 예식장"만 표기.

## 6. 디자인 규칙

- 홈페이지(`html.sky`)는 **어두운 우주/오로라 테마** + 브랜드 주황(#f2681c 계열). 은은하고 고급스럽게, 과하게 여성스럽지 않게.
- 관리자 화면은 밝은 토스 스타일(흰 카드, #3182f6 파랑, 넓은 여백, 둥근 모서리).
- 스크롤 시 `rs-rev` 요소가 페이드인. 새 섹션에도 `class="rs-rev"` 부여.
- **모바일 가독성 최우선**: 글자 크기 과하지 않게, 문장 단위 줄바꿈, 버튼 44px 이상.
- 대비 부족(어두운 배경 위 흐린 글씨) 주의 — 사용자가 여러 번 지적한 부분.

---

## 7. 작업 방식 (사용자와 합의된 흐름)

1. 요청을 받으면 **바꿀 부분만** 최소한으로 수정. 요청 안 한 디자인/문구는 건드리지 말 것.
2. 로컬 미리보기: 저장소 루트에서 `npx serve .` (또는 `python3 -m http.server 3000`) → 브라우저 `http://localhost:3000`
   - 미리보기도 **실제 Supabase에 연결**됨. 테스트 예약을 넣으면 실제 데이터가 생김 → 사용자에게 미리 경고.
   - 카카오 로그인은 localhost에서 안 될 수 있음 → 관리자 확인은 배포 사이트에서.
3. 사용자가 확인하면 `git add` → `git commit -m "한국어로 무엇을 바꿨는지"` → `git push`.
   push 전에 변경 요약을 보여주고 허락 받기.
4. push 후 "1~2분 뒤 roman-story.com 에서 강력 새로고침(Cmd+Shift+R)으로 확인하세요" 안내.
5. Supabase SQL이 필요하면 SQL 전문을 채팅에 그대로 보여주고, 붙여넣을 위치(SQL Editor → New query → Run)를 알려줄 것.

## 8. 알려진 주의사항 / 과거 이슈

- 시크릿 모드에서 데이터가 안 보이던 문제 → slug를 URL(`?studio=`) 또는 기본값 `eodnd1254`로 결정하도록 해결됨.
- 계약서 PDF: html2pdf로 전체를 캔버스로 렌더한 뒤 **줄 경계에서만 페이지를 자름**(onIssue 함수). 페이지 잘림 재발 시 이 로직부터 확인.
- 스틸컷(히어로 사진) 삭제 시 자동 저장됨. 갤러리가 비면 heroPhoto도 비움.
- 오픈 이벤트 배너: 관리자 CMS의 켜기/끄기 스위치(`eventBannerEnabled`) + 고객용 "오늘 하루 보지 않기".
- GitHub 웹 업로드는 25MB 제한 → 대용량 단일 파일(standalone) 쓰지 말고 지금 구조 유지.
