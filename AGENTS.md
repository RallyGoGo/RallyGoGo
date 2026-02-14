# AGENTS.md

## Project Context & Operations

### Project Context
- RallyGoGo는 테니스 매칭/경기 운영을 위한 React + Supabase 기반 애플리케이션입니다.
- 프론트엔드는 Vite 기반 SPA이며, 데이터 접근은 Supabase 클라이언트와 RPC를 통해 수행합니다.
- 데이터 보안 모델은 RLS와 서버 측 검증을 전제로 합니다.

### Tech Stack Summary
- Frontend: React 19, TypeScript, Vite 7
- Styling: Tailwind CSS 4, PostCSS
- Backend Platform: Supabase (PostgreSQL, RPC, Auth, Realtime)
- Tooling: ESLint, TypeScript Compiler

### Operational Commands
- 개발 서버: `npm run dev`
- 프로덕션 빌드: `npm run build`
- 빌드 결과 확인: `npm run preview`
- 정적 분석: `npm run lint`
- 타입 검사: `npx tsc --noEmit`
- 로컬 Supabase 시작: `npx supabase start`
- 로컬 DB 리셋: `npx supabase db reset`
- 마이그레이션 반영: `npx supabase db push`

## Golden Rules

### Immutable
1. 프론트엔드 코드에서 `INSERT/UPDATE/DELETE`를 직접 실행하지 않습니다. 상태 변경은 원칙적으로 RPC 경유를 우선합니다.
2. Supabase 클라이언트 진입점은 `/Users/youngs/Desktop/rallygogo/src/lib/supabase.ts` 하나로 고정합니다.
3. API 키, 토큰, 비밀값을 코드/로그/커밋 메시지에 하드코딩하지 않습니다.
4. 인증/권한 검증은 우회하지 않으며, RLS를 무력화하는 변경을 금지합니다.

### Do
- RPC 호출 시 함수명과 파라미터 키를 명시적으로 작성하고, 응답 타입을 함께 정의합니다.
- 타입을 먼저 설계하고 구현합니다. `any`가 필요하면 최소 범위로 제한하고 이유를 남깁니다.
- 에러는 사용자 메시지와 내부 로그 메시지를 분리합니다.
- 보안/아키텍처 규칙과 코드가 어긋나면 문서 갱신 또는 수정 PR을 함께 제안합니다.

### Don't
- `supabase.from(...).insert/update/delete`를 관성적으로 추가하지 않습니다.
- 토큰, 이메일, 전화번호 등 민감한 값을 로그에 남기지 않습니다.
- 기존 마이그레이션 파일을 임의 수정해 히스토리를 재작성하지 않습니다.
- 동작 근거 없이 스키마를 임의 변경하지 않습니다.

## Standards & References

### Coding Standards
- TypeScript strict 기반으로 구현하고 암시적 타입 의존을 줄입니다.
- React 함수형 컴포넌트와 Hooks 패턴을 유지합니다.
- 공통 데이터 접근/타입은 `src/lib`, `src/types`를 우선 사용합니다.

### Git Strategy & Commit Message
- 기본 브랜치에서 직접 작업하지 않고 기능 단위 브랜치로 작업합니다.
- 커밋 메시지는 `type(scope): summary` 형식을 권장합니다.
- 작은 단위로 커밋하고, DB 변경은 앱 변경과 영향 관계를 메시지에 명시합니다.

### Legacy Reference
- `/Users/youngs/Desktop/rallygogo/AGENT.md`는 레거시 가이드로 보존합니다.
- 신규 규칙 해석은 이 파일(`AGENTS.md`)과 하위 `AGENTS.md` 체계를 우선합니다.

## Maintenance Policy

- 규칙과 실제 코드가 충돌하면 코드를 기준으로 숨기지 말고 문서를 즉시 업데이트합니다.
- 새 상위 도메인(예: `scripts`, `infra`)이 생기면 해당 디렉터리에 `AGENTS.md` 추가 여부를 검토합니다.
- 루트 `Context Map`은 실제 파일 구조와 항상 동기화합니다.
- 오래된 규칙은 삭제하거나 Deprecated 상태를 명시합니다.

## Context Map

- **[프론트엔드 앱 코드 수정](./src/AGENTS.md)** — React 컴포넌트, 훅, 서비스, 타입, 유틸 변경 시 적용합니다.
- **[Supabase 스키마 및 RPC 수정](./supabase/AGENTS.md)** — 마이그레이션, SQL 함수, RLS, 로컬 DB 운영 시 적용합니다.
