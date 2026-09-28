# 검증 기록

## T4 UI 구현 작업 트리

- 범위: CalendarUI, CalendarUITests, README, 이 문서. 앱 진입점 연결 및 실제 화면 검증은 통합 작업에서 수행합니다.
- `python3 scripts/run.py 300 swift test --jobs 2 --filter CalendarUITests`: 구현 전 exit 1. `MonthSwipe`, `CalendarModel` 미정의로 실패(RED).
- 동일 명령: 구현 후 exit 0, 2개 테스트 통과(GREEN). 드래그 방향·40pt 경계·수직/동률 제외, 1월31일→2월28일 clamp, 인접 월 날짜 선택, 날짜 갱신의 탐색 월 유지, 재열기 오늘 복귀를 검증했습니다.
- 테스트 백엔드는 권한 요청 시 실패하도록 구성했습니다. 실제 TCC 요청, 개인 캘린더 조회, 로그인 항목 등록은 이 작업 트리에서 실행하지 않았습니다.
- 참고 이미지 `.dryforge/assets/calendar-preview.png`를 확인하고 네이티브 색상·월 헤더·요일/날짜 그리드·일정/설정 구성을 구현했습니다. 실제 렌더 비교, 드래그가 날짜 클릭을 유발하지 않는지, 키보드/VoiceOver, 시스템 계정 및 ServiceManagement 통합은 아직 여기서 검증하지 않았습니다.

- 전체 `python3 scripts/run.py 300 swift test --jobs 2`: exit 0, 최종 25개 테스트 통과(UI 3개). 추가 UI 테스트는 빠른 연속 월/날짜 선택 후 최종 그리드 조회 구간 일치, 종일/진행 중 레이블을 검증합니다. SwiftUI 모듈 및 실행 파일 링크도 성공했습니다.
