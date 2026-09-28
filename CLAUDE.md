# Calendar Bar

개인 맥에서 오늘 날짜와 일정 유무를 확인하는 Swift 네이티브 메뉴막대 앱이다.
일정 관리는 구글 캘린더에서 하고, 이 앱은 macOS에 동기화된 선택 캘린더를 읽는다.

## 프로젝트 구조

```text
.
├── AGENTS.md                         → 작업 진입점
├── CLAUDE.md                         → 같은 작업 규칙
├── docs/
│   ├── architecture.md               → 구성과 데이터 흐름
│   ├── business-rules.md             → 날짜·선택·일정 규칙
│   ├── security.md                   → 권한과 개인정보 경계
│   ├── standards.md                  → 변경 및 검증 기준
│   ├── engineering-notes.md          → 실제로 확인한 구현 주의점
│   ├── operations.md                 → 빌드·실행·연결 절차
│   ├── contracts.md                  → macOS 연동 계약
│   ├── verification.md               → 실행한 검증과 미검증 범위
│   └── tracking/
│       ├── status.md                 → 구현 현황과 남은 확인
│       ├── findings.md               → 해결하지 못한 문제
│       └── decisions/
│           ├── index.md              → 결정 목록
│           ├── 0001-system-calendar.md → 시스템 캘린더 읽기 선택 이유
│           └── 0002-local-reminders.md → 종료 중 알림과 갱신의 절충
└── Sources/
    ├── CalendarBar/AGENTS.md          → 앱 진입과 수명 연결
    ├── CalendarCore/AGENTS.md         → 날짜와 일정 계산
    ├── CalendarAccess/AGENTS.md        → 시스템 일정 조회
    ├── CalendarNotifications/AGENTS.md → 앱 알림 예약과 복구
    ├── MenuBar/AGENTS.md               → 팝오버·로그인 항목
    └── CalendarUI/AGENTS.md            → 화면과 제스처
```

## 핵심 기준

- 앱은 일정을 읽기만 한다. 일정 저장·수정·삭제 API를 추가하지 않는다.
- 비밀과 개인 일정 내용을 코드·로그·검증 자료에 기록하지 않는다.
- 성공을 보고하기 전에 변경에 맞는 테스트와 실제 동작을 확인하고 미검증 부분을 구별한다.
- 장시간 실행에는 제한 시간을 두고 검증 프로세스 종료를 확인한다.

## 작업 전 확인

`docs/standards.md`, `docs/engineering-notes.md`, 해당 모듈의 `AGENTS.md`를 읽는다.
날짜·제스처 변경 전에는 `docs/business-rules.md`, 권한이나 저장 변경 전에는 `docs/security.md`와 `docs/contracts.md`, 앱 배치·로그인 실행 변경 전에는 `docs/operations.md`를 확인한다.

일정에 쓰는 호출, 권한 회수 뒤 개인 일정 노출, 비밀 유출은 즉시 사용자에게 보고한다. 나머지 미해결 문제는 재현 조건과 미해결 이유를 `docs/tracking/findings.md`에 기록한다.
