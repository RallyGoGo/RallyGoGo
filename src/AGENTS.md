# src AGENTS.md

## Module Context

- `src`는 사용자 인터페이스, 인증 상태, 실시간 데이터 구독, 앱 레벨 상태 동기화를 담당합니다.
- 도메인별 책임은 다음을 기준으로 분리합니다.
- `components`: 화면 단위 UI 및 이벤트 핸들링
- `hooks`: 데이터 패칭/구독/상태 오케스트레이션
- `services`: 계산 로직과 RPC 호출 래핑
- `lib`: 외부 클라이언트 초기화 및 공용 타입 노출
- `types`: 앱/DB 타입 정의
- `utils`: 로깅/정책성 유틸

## Tech Stack & Constraints

- React 함수형 컴포넌트와 Hooks만 사용합니다.
- TypeScript를 기본으로 하며 암시적 `any`는 허용하지 않는 방향으로 유지합니다.
- Supabase 접근은 `src/lib/supabase.ts`를 통해서만 수행합니다.
- 비즈니스 규칙 계산은 `src/services`에 두고, 컴포넌트 내부에서 중복 구현하지 않습니다.
- UI 코드에서 민감 데이터/토큰/키를 출력하지 않습니다.

## Implementation Patterns

### Hooks Pattern
- `useRallyData` 계열 훅에서는 다음 분리를 유지합니다.
- `fetch*` 함수: `useCallback`으로 선언하고 단일 책임으로 유지
- 구독/해제: `useEffect` 내부에서 등록 후 cleanup에서 해제
- 초기화 실패 대비: 타임아웃 또는 fallback 경로를 명시

### Service Pattern
- `src/services/*`는 가능한 한 순수 함수와 명시적 입출력을 유지합니다.
- RPC 래퍼 함수는 RPC 이름/파라미터 키를 코드에 명시하고 반환 타입을 고정합니다.
- 서비스 레이어는 React 상태를 직접 변경하지 않습니다.

### Type Pattern
- API/RPC 응답은 타입 별칭으로 선언하고 성공/실패 형태를 구분합니다.
- `any`가 불가피할 때만 최소 범위로 사용하고, 사용 이유를 한 줄 주석으로 남깁니다.
- 런타임 확장 데이터가 있으면 전용 확장 타입을 추가합니다.

### Logging Pattern
- `src/utils/logger.ts`를 통해 구조화 로그를 남깁니다.
- 사용자 노출 메시지와 개발자 로그 메시지를 분리합니다.

## Testing Strategy

- 변경 전후 최소 점검:
- `npm run lint`
- `npx tsc --noEmit`

- 변경 유형별 점검:
- 훅 변경: 인증 상태 변화, 초기 fetch, realtime 반응, cleanup 동작 확인
- 서비스 변경: 입력 경계값, 예외 처리, RPC 실패 시 처리 확인
- 컴포넌트 변경: 로딩/에러/빈 상태 UI를 각각 확인

- 배포 전 점검:
- `npm run build`로 번들/타입 관련 회귀를 확인합니다.

## Local Golden Rules

### Do
- 데이터 변경 경로를 먼저 확인하고 UI 액션과 RPC 호출을 일치시킵니다.
- 상태 필드와 DB enum/status 문자열을 상수 또는 타입으로 관리합니다.
- 타입이 애매하면 구현 전에 타입부터 추가합니다.

### Don't
- 컴포넌트에서 대규모 비즈니스 로직을 직접 계산하지 않습니다.
- Hooks 내부에서 cleanup 없는 구독을 추가하지 않습니다.
- 임시 디버그 로그를 민감 정보와 함께 남기지 않습니다.
